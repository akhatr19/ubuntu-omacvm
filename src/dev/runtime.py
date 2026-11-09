"""The developer VM lifecycle. The app's existing QEMU/runtime stays authoritative."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import secrets
import socket
import subprocess
import sys
import time

from manifest import digest, fingerprint, write_json

ROOT = Path(__file__).resolve().parents[2]
HOME = Path(os.environ.get('UVM_HOME', Path.home() / 'Library/Application Support/UbuntuVM')).expanduser().resolve()
VMS = Path(os.environ.get('UVM_VMS_ROOT', Path.home() / 'UbuntuVMs')).expanduser().resolve()
RUNTIME_COMMIT = 'fc0dc8f2140190ba7ed6718f14ac65196410242c'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def app_bundle():
    if os.environ.get('UVM_APP'):
        app = Path(os.environ['UVM_APP']).resolve()
    elif ROOT.name == 'omacvm' and ROOT.parent.name == 'Resources':
        app = ROOT.parents[2]
    else:
        choices = [Path.home() / 'Applications/UbuntuVM.app', Path('/Applications/UbuntuVM.app'),
                   ROOT / 'app/dist/UbuntuVM.app']
        app = next((p for p in choices if p.is_dir()), None)
    if not app or not (app / 'Contents/Resources/runtime/bin/OmacVM').is_file():
        raise ValueError('UbuntuVM.app is required; build or install it first')
    return app


def runtime_identity():
    resources = app_bundle() / 'Contents/Resources'
    files = sorted(p for p in (resources / 'runtime').rglob('*') if p.is_file())
    files.append(resources / 'firmware/edk2-aarch64-code.fd')
    return fingerprint({str(p.relative_to(resources)): digest(p) for p in files})


def vm_folder(name):
    import re
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,39}', name):
        raise ValueError('invalid environment name')
    prefix = 'OmacVM Test-Dev-' if os.environ.get('UVM_TEST_MODE') == '1' else 'Dev-'
    return VMS / (prefix + name)


def private_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f'private directory is a symlink: {path}')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.stat().st_uid != os.getuid():
        raise ValueError(f'private directory has another owner: {path}')
    path.chmod(0o700)
    return path


def sockets(vm):
    parent = private_dir(Path('/tmp') / f'uvm-{os.getuid()}')
    key = hashlib.sha256(str(vm.resolve()).encode()).hexdigest()[:16]
    return private_dir(parent / key)


def config(vm):
    path = Path(vm) / 'uvm-env.json'
    if not path.is_file():
        raise ValueError('not a managed developer environment')
    if path.stat().st_size > 1024 * 1024:
        raise ValueError('environment metadata is too large')
    return json.loads(path.read_text())


def live(vm):
    """A stale PID never authorizes killing a different process."""
    file = sockets(vm) / 'state.json'
    if not file.exists():
        return None
    state = json.loads(file.read_text())
    pid = state.get('qemu_pid')
    if type(pid) is not int or pid <= 0:
        return None
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True)
    disk = 'file=' + str(vm / 'disk.img').replace(',', ',,') + ','
    return state if result.returncode == 0 and disk in result.stdout else None


def disk_busy(vm):
    result = subprocess.run(['lsof', '-t', str(vm / 'disk.img')], capture_output=True, text=True)
    return result.returncode == 0


def socket_request(path, command, arguments=None, qga=False):
    message = {'execute': command}
    if arguments is not None:
        message['arguments'] = arguments
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        stream = connection.makefile('rwb', buffering=0)
        if qga:
            nonce = secrets.randbits(63)
            stream.write(b'\xff' + json.dumps({'execute': 'guest-sync-delimited', 'arguments': {'id': nonce}}).encode() + b'\n')
            while True:
                line = stream.readline(8 * 1024 * 1024)
                if not line:
                    raise RuntimeError('guest agent closed during synchronization')
                try:
                    answer = json.loads(line.rsplit(b'\xff', 1)[-1])
                    if answer.get('return') == nonce:
                        break
                except ValueError:
                    continue
        else:
            stream.readline(1024 * 1024)
            stream.write(b'{"execute":"qmp_capabilities"}\n')
            while 'return' not in json.loads(stream.readline(1024 * 1024)):
                pass
        stream.write(json.dumps(message).encode() + b'\n')
        while True:
            line = stream.readline(8 * 1024 * 1024)
            if not line:
                raise RuntimeError('VM control socket closed')
            answer = json.loads(line)
            if 'error' in answer:
                raise RuntimeError(str(answer['error']))
            if 'return' in answer:
                return answer['return']


def guest_agent(vm, script, timeout=90):
    path = sockets(vm) / 'qga'
    pid = socket_request(path, 'guest-exec', {'path': '/bin/bash', 'arg': ['-c', script],
                                            'capture-output': True}, qga=True)['pid']
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = socket_request(path, 'guest-exec-status', {'pid': pid}, qga=True)
        if result.get('exited'):
            output = base64.b64decode(result.get('out-data', ''))
            if result.get('exitcode') != 0:
                raise RuntimeError('guest bootstrap failed: ' + base64.b64decode(result.get('err-data', '')).decode(errors='replace')[-2000:])
            return output
        time.sleep(.1)
    raise TimeoutError('guest bootstrap did not finish')


def bootstrap(vm, state):
    """Replace inherited image credentials and pin SSH through the private guest-agent socket."""
    metadata = config(vm)
    user = metadata['user']
    key = (vm / 'ssh-key.pub').read_text().strip()
    script = '''set -euo pipefail
U=%s
KEY=%s
if [[ %s == new ]]; then
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  systemd-id128 new > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  install -d /var/lib/uvm
  touch /var/lib/uvm/identity
install -d -m700 /root/.ssh
printf '%%s\\n' "$KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
H=$(getent passwd "$U" | cut -d: -f6)
printf '%%s\\n' "$KEY" | runuser -u "$U" -- env HOME="$H" bash -c '
set -e; umask 077; mkdir -p "$HOME/.ssh"; t=$(mktemp "$HOME/.ssh/.uvm.XXXXXX"); cat > "$t"; mv "$t" "$HOME/.ssh/authorized_keys"'
fi
hostnamectl set-hostname %s
systemctl stop gdm3.service 2>/dev/null || true
systemctl restart ssh.service
cat /etc/ssh/ssh_host_ed25519_key.pub
''' % (shlex.quote(user), shlex.quote(key), 'new' if not (vm / 'identity-ready').exists() else 'existing', shlex.quote(metadata['name']))
    public = guest_agent(vm, script).decode().strip().splitlines()[-1]
    if not public.startswith('ssh-ed25519 '):
        raise RuntimeError('guest returned no SSH host key')
    (vm / 'known_hosts').write_text(f'[127.0.0.1]:{state["ssh_port"]} {public}\n')
    (vm / 'known_hosts').chmod(0o600)
    (vm / 'identity-ready').touch(mode=0o600)


def ssh_args(vm, root=False, tty=False, agent=False):
    state = live(vm)
    if not state or not state.get('ready'):
        raise ValueError('environment is not running; use uvm up')
    user = 'root' if root else config(vm)['user']
    known = str(vm / 'known_hosts').replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    args = ['ssh', '-F', '/dev/null', '-i', str(vm / 'ssh-key'), '-p', str(state['ssh_port']),
            '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=15', '-o', 'StrictHostKeyChecking=yes',
            '-o', f'UserKnownHostsFile="{known}"']
    if tty:
        args.append('-t')
    if agent:
        args.append('-A')
    return args + [f'{user}@127.0.0.1']


def ssh(vm, command, root=False, **kwargs):
    return run(ssh_args(vm, root=root) + [command], **kwargs)


def ensure_up(vm, desktop=False):
    current = live(vm)
    if current and current.get('ready'):
        if desktop and current['mode'] != 'desktop':
            stop(vm)
            current = None
        else:
            return current
    process = None
    if not current:
        if disk_busy(vm):
            raise ValueError('this environment is open in the desktop app; stop it there before headless use')
        log = open(vm / 'logs/developer.log', 'ab')
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('uvm.py')), '_supervise', str(vm),
                                    *(['--desktop'] if desktop else [])],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    end = time.monotonic() + 240
    while time.monotonic() < end:
        current = live(vm)
        if current and current.get('ready'):
            if desktop and current['mode'] != 'desktop':
                return ensure_up(vm, desktop=True)
            return current
        if process is not None and process.poll() is not None and not current:
            raise RuntimeError(f'VM startup failed; see {vm / "logs/developer.log"}')
        time.sleep(.25)
    raise TimeoutError(f'VM did not become ready; see {vm / "logs/developer.log"}')


def stop(vm, force=False):
    state = live(vm)
    if not state:
        if disk_busy(vm):
            raise ValueError('environment belongs to the desktop app; shut it down there')
        wait_for_owner(vm)
        return
    socket_request(sockets(vm) / 'qmp', 'quit' if force else 'system_powerdown')
    end = time.monotonic() + (15 if force else 90)
    while live(vm) and time.monotonic() < end:
        time.sleep(.25)
    if live(vm):
        raise TimeoutError('guest did not shut down; use --force only if data loss is acceptable')
    wait_for_owner(vm)


def wait_for_owner(vm):
    """QEMU can exit before its supervisor has closed forwards and released ownership."""
    with open(sockets(vm) / 'owner.lock', 'a') as owner:
        deadline = time.monotonic() + 15
        while True:
            try:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('the background supervisor is still closing; retry shortly')
                time.sleep(.05)


def local_resources(vm):
    """Honor local resource changes made by the app without rewriting the portable manifest."""
    import re
    text = (vm / 'vm.env').read_text()
    values = {}
    for field in ('CPUS', 'MEM_MB'):
        match = re.search(r'^' + field + r'=([0-9]+)$', text, re.M)
        if not match:
            raise ValueError('invalid local resources in vm.env')
        values[field] = int(match[1])
    if not 1 <= values['CPUS'] <= 256 or not 2048 <= values['MEM_MB'] <= 1048576:
        raise ValueError('local resources are out of range')
    return values


def qemu_plan(vm, port, desktop=False):
    metadata = config(vm)
    if metadata.get('runtime_sha256') and metadata['runtime_sha256'] != runtime_identity():
        raise ValueError('installed runtime differs from this environment; use its pinned app build')
    app = app_bundle()
    resources = app / 'Contents/Resources'
    runtime = resources / 'runtime/bin/OmacVM'
    run_dir = sockets(vm)
    local = local_resources(vm)
    def q(path): return str(path).replace(',', ',,')
    args = [str(runtime), '-name', metadata['vm_name'], '-machine', 'virt,gic-version=3',
            '-accel', 'hvf', '-cpu', 'host,pmu=off', '-smp', str(local['CPUS']),
            '-m', str(local['MEM_MB']) + 'M', '-nodefaults',
            '-action', 'reboot=reset,shutdown=poweroff', '-boot', 'menu=on,splash-time=0',
            '-drive', f'if=pflash,format=raw,readonly=on,file={q(resources / "firmware/edk2-aarch64-code.fd")}',
            '-drive', f'if=pflash,format=raw,file={q(vm / "efi-vars.fd")}',
            '-drive', f'if=none,id=disk,file={q(vm / "disk.img")},format=raw,cache=writeback,discard=unmap',
            '-device', 'nvme,serial=omacvm,drive=disk,bootindex=0',
            '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
            '-device', 'virtio-net-pci,netdev=net0,romfile=',
            '-device', 'virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,blob=true,venus=true,hostmem=8192M,romfile=',
            '-display', 'cocoa,gl=on,show-cursor=off,full-screen=off,full-grab=off,zoom-to-fit=on',
            '-device', 'virtio-keyboard-pci', '-device', 'virtio-tablet-pci', '-device', 'virtio-rng-pci',
            '-device', 'virtio-balloon-pci,free-page-reporting=on', '-device', 'virtio-serial-pci,id=vser0',
            '-chardev', f'socket,id=qga,path={q(run_dir / "qga")},server=on,wait=off',
            '-device', 'virtserialport,bus=vser0.0,nr=1,chardev=qga,name=org.qemu.guest_agent.0',
            '-chardev', f'socket,id=host,path={q(run_dir / "host")},server=on,wait=off',
            '-device', 'virtserialport,bus=vser0.0,nr=2,chardev=host,name=org.ubuntu.vm.host',
            '-qmp', f'unix:{q(run_dir / "qmp")},server=on,wait=off',
            '-serial', f'file:{q(vm / "logs/developer-console.log")}', '-monitor', 'none']
    for value in ('omacvm.vkwindows=1', 'omacvm.vaexport=1', 'omacvm.vadecasync=1', 'omacvm.valogical=1'):
        args.extend(['-smbios', 'type=11,value=' + value])
    env = os.environ.copy()
    env.update(OMACVM_COCOA_HIDDEN='1', OMACVM_SLIRP_HOST_PORTS='', OMACVM_VIDEO_AV1='1', OMACVM_HW_CURSOR='1',
               OMACVM_GPU_MEMORY_STATUS=str(vm / 'logs/gpu-memory'), OMACVM_PRODUCT_NAME='UbuntuVM')
    if desktop and not (os.environ.get('UVM_TEST_MODE') == '1' and os.environ.get('OMACVM_COCOA_HIDDEN') == '1'):
        env.pop('OMACVM_COCOA_HIDDEN', None)
    return args, env
