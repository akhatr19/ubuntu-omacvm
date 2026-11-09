"""One owner per headless VM: QEMU, opt-in interop, localhost forwarding and idle policy."""
import fcntl
import os
import re
from pathlib import Path
import socket
import subprocess
import threading
import time

from interop import serve
from manifest import write_json
import network
from runtime import bootstrap, config, disk_busy, guest_agent, live, qemu_plan, sockets, ssh_args, socket_request


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def listening_ports(output):
    ports = {}
    for line in output.splitlines():
        if '"containerd"' in line:
            continue  # Its internal metrics listener is not a published container port.
        fields = line.split()
        if len(fields) >= 4:
            try:
                port = int(fields[3].rsplit(':', 1)[1])
            except (ValueError, IndexError):
                continue
            if 1024 <= port <= 65535:
                address = fields[3].rsplit(':', 1)[0].strip('[]')
                target = '[::1]' if address in ('::1', '::') else '127.0.0.1'
                if port not in ports or target == '127.0.0.1':
                    ports[port] = target
    return ports


def connect_master(vm, control):
    args = ssh_args(vm, root=True, allow_starting=True)
    args[-1:-1] = ['-M', '-S', control, '-o', 'ControlPersist=no', '-N']
    process = None
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if process is None or process.poll() is not None:
            Path(control).unlink(missing_ok=True)
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL)
        try:
            result = subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'check', 'root@127.0.0.1'],
                                    capture_output=True, timeout=5)
        except subprocess.TimeoutExpired:
            continue
        if result.returncode == 0:
            return process, args
        time.sleep(.25)
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
    raise TimeoutError('Ubuntu did not finish starting its SSH server')


def supervise(vm, desktop=False):
    metadata = config(vm)
    settings = metadata['manifest']
    local = network.load(vm, settings)
    if any(p['host'] == metadata['ssh_port'] for p in local['ports']) or (local['ssh_lan'] and local['ssh_port'] == metadata['ssh_port']):
        raise ValueError('published ports must differ from the private management SSH port')
    run_dir = sockets(vm)
    owner = open(run_dir / 'owner.lock', 'a')
    try:
        fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise ValueError('another lifecycle operation owns this environment')
    if disk_busy(vm):
        raise ValueError('VM disk is already open')
    for name in ('qmp', 'qga', 'host', 'ssh-control'):
        file = run_dir / name
        if file.exists():
            file.unlink()
    port = metadata['ssh_port']
    args, environment = qemu_plan(vm, port, desktop)
    process = subprocess.Popen(args, env=environment)
    state = {'qemu_pid': process.pid, 'supervisor_pid': os.getpid(), 'ssh_port': port,
             'ready': False, 'ports': [], 'conflicts': [], 'mode': 'desktop' if desktop else 'headless'}
    state_file = run_dir / 'state.json'
    write_json(state_file, state)
    stopped = threading.Event()
    thread = threading.Thread(target=serve, args=(run_dir / 'host', settings['interop'],
                              Path.home() / 'Downloads/UbuntuVM' / settings['name'], stopped), daemon=True)
    thread.start()
    master = None
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('QEMU exited before boot completed')
            try:
                socket_request(run_dir / 'qga', 'guest-ping', qga=True)
                break
            except (OSError, ValueError, RuntimeError):
                time.sleep(.5)
        else:
            raise TimeoutError('guest agent did not answer')
        first_boot = not (vm / 'identity-ready').exists()
        boot_id = guest_agent(vm, 'cat /proc/sys/kernel/random/boot_id')
        bootstrap(vm, state)
        if first_boot:
            # Boot once with the new machine-id, not just a changed file under a running D-Bus.
            try:
                guest_agent(vm, 'sync; systemctl reboot --no-block', timeout=5)
            except (OSError, RuntimeError, TimeoutError):
                pass
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                try:
                    if guest_agent(vm, 'cat /proc/sys/kernel/random/boot_id', timeout=5) != boot_id:
                        bootstrap(vm, state)
                        break
                except (OSError, ValueError, RuntimeError, TimeoutError):
                    pass
                time.sleep(.5)
            else:
                raise TimeoutError('new environment did not reboot with its unique identity')
        control = str(run_dir / 'ssh-control')
        master, master_args = connect_master(vm, control)
        state['ready'] = True
        write_json(state_file, state)
        if desktop:
            guest_agent(vm, 'systemctl start --no-block gdm3.service')
        forwards = {}
        required = {p['host']: (p['guest'], '0.0.0.0' if p['lan'] else '127.0.0.1') for p in local['ports']}
        if local['ssh_lan']:
            required[local['ssh_port']] = (22, '0.0.0.0')
        idle_since = time.monotonic()
        while process.poll() is None:
            if master.poll() is not None:
                forwards.clear()
                (run_dir / 'ssh-control').unlink(missing_ok=True)
                master = subprocess.Popen(master_args, stdin=subprocess.DEVNULL)
                time.sleep(.5)
            command = ssh_args(vm, root=True)
            # Probes must not race the dedicated master to create its socket.
            command[-1:-1] = ['-S', control, '-o', 'ControlMaster=no']
            try:
                result = subprocess.run(command + ["ss -H -ltnp; printf '\\nUVM_DOCKER\\n'; docker ps --format '{{json .Ports}}' 2>/dev/null; printf '\\nUVM_SESSIONS\\n'; ps -eo args= | grep '^sshd'"],
                                        capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                continue
            text, _, sessions = result.stdout.partition('UVM_SESSIONS')
            listeners, _, containers = text.partition('UVM_DOCKER')
            discovered = listening_ports(listeners) if result.returncode == 0 else {}
            for value in re.findall(r':([0-9]+)->[0-9]+/tcp', containers):
                candidate = int(value)
                if 1024 <= candidate <= 65535:
                    discovered.setdefault(candidate, '127.0.0.1')
            # Keep a guest with many listeners from consuming unlimited host forwards.
            discovered = dict(sorted(discovered.items())[:64])
            desired = {h: (g, discovered.get(g, '127.0.0.1'), bind) for h, (g, bind) in required.items()}
            if local['auto_ports']:
                desired.update({p: (p, address, '127.0.0.1') for p, address in discovered.items() if p != port and p not in required})
            conflicts = []
            for host, (guest, address, bind) in list(forwards.items()):
                if desired.get(host) != (guest, address, bind):
                    subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'cancel', '-L', f'{bind}:{host}:{address}:{guest}', '-p', str(port), 'root@127.0.0.1'],
                        capture_output=True)
                    del forwards[host]
            for host, (guest, address, bind) in desired.items():
                if host in forwards:
                    continue
                request = ['ssh', '-F', '/dev/null', '-S', control, '-O', 'forward', '-o', 'ExitOnForwardFailure=yes',
                           '-L', f'{bind}:{host}:{address}:{guest}', '-p', str(port), 'root@127.0.0.1']
                result = subprocess.run(request, capture_output=True)
                if result.returncode == 0:
                    forwards[host] = (guest, address, bind)
                else:
                    conflicts.append(host)
            state.update(ports=[{'host': h, 'guest': g, 'address': address, 'bind': bind} for h, (g, address, bind) in sorted(forwards.items())], conflicts=conflicts)
            write_json(state_file, state)
            leases = list((run_dir / 'leases').glob('*')) if (run_dir / 'leases').exists() else []
            active = discovered or containers.strip() or any(f': {metadata["user"]}@' in line for line in sessions.splitlines())
            for lease in leases:
                try:
                    os.kill(int(lease.name), 0)
                    active = True
                except (ProcessLookupError, PermissionError, ValueError):
                    lease.unlink(missing_ok=True)
            if active:
                idle_since = time.monotonic()
            minutes = local['idle_minutes']
            if minutes and not desktop and time.monotonic() - idle_since >= minutes * 60:
                socket_request(run_dir / 'qmp', 'system_powerdown')
                idle_since = time.monotonic()
            time.sleep(3)
    finally:
        stopped.set()
        if master and master.poll() is None:
            master.terminate()
            master.wait(timeout=10)
        if process.poll() is None:
            try:
                socket_request(run_dir / 'qmp', 'system_powerdown')
                process.wait(timeout=90)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                print('VM is still running; stop it explicitly before copying its disk', flush=True)
        if process.poll() is not None:
            state_file.unlink(missing_ok=True)
