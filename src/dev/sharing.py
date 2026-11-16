"""Shared folders: one private Linux disk owner, live NFS clients and Mac Finder."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

import files
from manifest import write_json
import network
import runtime as rt
import volumes
from workspace import Session

CLIENTS = 'shared-folders.json'


@contextlib.contextmanager
def client_locked(vm):
    with open(rt.sockets(vm) / 'shared-config.lock', 'a') as lock:
        deadline = time.monotonic() + 15
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic() >= deadline: raise ValueError('this VM is connecting shared folders; retry when it finishes')
                time.sleep(.1)
        yield


def descriptor(vm, identity):
    folder, record = volumes.volume(vm, identity)
    share = volumes.read(folder / 'sharing.json')
    server = Path(share['server'])
    if share.get('id') != identity or server.parent != volumes.library(vm) / '.ubuntu-services' or server.is_symlink():
        raise ValueError('invalid file service metadata')
    if type(share.get('nfs_port')) is not int or not 1024 <= share['nfs_port'] <= 65535:
        raise ValueError('invalid file service port')
    members = share.get('clients')
    if not isinstance(members, list) or len(members) > 512 or any(not isinstance(path, str) or len(path) > 4096 or Path(path).parent != volumes.library(vm) for path in members):
        raise ValueError('invalid shared folder connections')
    if record.get('shared') is not True or record.get('attached_vm') != str(server):
        raise ValueError('shared data is not owned by its file service')
    if not server.is_dir(): raise ValueError('the file service is missing; its data disk was preserved')
    return folder, record, share, server


def clients(vm):
    path = Path(vm) / CLIENTS
    data = volumes.read(path) if path.exists() or path.is_symlink() else {'schema': 1, 'folders': []}
    rows = data.get('folders')
    if not isinstance(rows, list) or len(rows) > 16: raise ValueError('invalid shared folder settings')
    seen = set()
    identities = set()
    for row in rows:
        if not isinstance(row, dict) or not re.fullmatch(r'[0-9a-f]{32}', str(row.get('id', ''))): raise ValueError('invalid shared folder')
        if type(row.get('port')) is not int or not 1024 <= row['port'] <= 65535 or row['port'] in seen: raise ValueError('invalid shared folder port')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 _.-]{0,60}', str(row.get('folder', ''))) or '..' in row['folder']: raise ValueError('invalid shared folder path')
        if row['id'] in identities: raise ValueError('duplicate shared folder')
        identities.add(row['id'])
        seen.add(row['port'])
    return rows


def arguments(vm):
    return [value for row in clients(vm) for value in ('-smbios', 'type=11,value=uvm.shared=' + row['id'])]


def listing(vm):
    result = []
    for record in volumes.listing(vm)['volumes']:
        file = volumes.store(vm) / record['id'] / 'sharing.json'
        if not file.exists(): continue
        _, record, share, server = descriptor(vm, record['id'])
        state = rt.live(server)
        result.append({'id': record['id'], 'name': record['name'], 'server_running': bool(state and state.get('ready')),
                       'clients': share.get('clients', []), 'size_gb': record['size_gb'],
                       'finder_port': volumes.read(server / 'finder-drive.json').get('port') if (server / 'finder-drive.json').exists() else None})
    status = Path(vm) / 'logs/shared-status.json'
    return {'folders': result, 'available': [row for row in volumes.listing(vm)['volumes'] if not row.get('shared')], 'connected': clients(vm), 'status': volumes.read(status) if status.exists() else None}


def create_server(vm, identity):
    from bundles import copy_disk
    from checkpoints import stopped
    from supervisor import free_port
    folder, record = volumes.volume(vm, identity)
    root = rt.private_dir(volumes.library(vm) / '.ubuntu-services')
    name = ('OmacVM Test-Files-' if os.environ.get('UVM_TEST_MODE') == '1' else 'Files-') + identity[:12]
    server = root / name
    if server.exists(): return server
    source = Session(vm, '/tmp')
    with stopped(vm):
        server.mkdir(mode=0o700)
        try:
            for file in ('disk.img', 'efi-vars.fd'): copy_disk(vm / file, server / file)
            port = free_port()
            settings = {'name': 'files-' + identity[:12], 'resources': {'cpus': 1, 'memory_gb': 2},
                        'ports': [], 'auto_ports': False, 'idle_minutes': None, 'ssh_agent': False, 'interop': []}
            write_json(server / 'uvm-env.json', {'schema': 1, 'name': settings['name'], 'vm_name': name,
                       'user': source.metadata['user'], 'manifest': settings, 'ssh_port': port})
            (server / 'vm.env').write_text(f"NAME='{name}'\nCPUS=1\nMEM_MB=2048\nSSH_PORT={port}\nVM_USER='{source.metadata['user']}'\n")
            (server / 'guest-os').write_text('ubuntu\n')
            (server / 'file-service').touch()
            rt.private_dir(server / 'logs')
            rt.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'uvm-file-service', '-f', server / 'ssh-key'])
        except BaseException:
            shutil.rmtree(server); raise
    return server


def create(vm, identity, name, size, password):
    # No personal VM is frozen/copied live. The first setup is explicit.
    volumes.idle(vm)
    if not 8 <= len(password) <= 256 or any(c in password for c in '\r\n\0'): raise ValueError('choose a Finder password of 8–256 characters')
    if identity is None:
        with volumes.locked(vm): identity = volumes.create(vm, name, size)['id']
    folder, record = volumes.volume(vm, identity)
    if (folder / 'sharing.json').exists(): raise ValueError('this disk already has a shared folder')
    if record.get('attached_vm') and Path(record['attached_vm']).parent != volumes.library(vm) / '.ubuntu-services':
        volumes.idle(Path(record['attached_vm']), folder / 'data.img')
    server = create_server(vm, identity)
    binding = server / volumes.BINDING
    prepared = volumes.attached(server) if binding.exists() and volumes.read(binding).get('ready') is True else None
    if prepared and prepared[1]['id'] != identity: raise ValueError('this file service already owns another disk')
    if not prepared:
        with volumes.locked(vm):
            volumes.prepare(server, identity, list(volumes.FOLDERS))
    try:
        rt.ensure_up(server)
        source = (rt.ROOT / 'src/ubuntu/guest/shared-files-server.sh').read_text()
        rt.guest_agent(server, 'SHARE_ID=' + shlex.quote(identity) + '\n' + source, timeout=900)
        session = Session(server, '/tmp')
        files.setup(session, password, personal_only=True)
        from supervisor import free_port
        share = {'schema': 1, 'id': identity, 'server': str(server), 'nfs_port': free_port(), 'clients': []}
        with volumes.locked(vm):
            _, record = volumes.volume(vm, identity)
            record['shared'] = True
            write_json(folder / 'volume.json', record)
            write_json(folder / 'sharing.json', share)
        print('Shared folder created. It can now be used by multiple running VMs.', flush=True)
        return share
    except BaseException:
        # The independent disk remains intact, owned by the visible-on-disk
        # service VM. Retrying creation must never format it again.
        if rt.live(server): rt.stop(server)
        raise


def server_tunnel(server, share):
    rt.ensure_up(server)
    with open(rt.sockets(server) / 'nfs-tunnel.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return server_tunnel_locked(server, share)


def server_tunnel_locked(server, share):
    control = str(rt.sockets(server) / 'nfs-ssh')
    destination = rt.ssh_args(server, root=True)[-1]
    check = subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'check', destination], capture_output=True)
    if check.returncode:
        Path(control).unlink(missing_ok=True)
        subprocess.run(rt.ssh_args(server, root=True)[:-1] + ['-M', '-S', control, '-f', '-N', '-o', 'ExitOnForwardFailure=yes',
                       '-L', f'127.0.0.1:{share["nfs_port"]}:127.0.0.1:2049', destination], check=True, timeout=30)


def guest_config(vm, row):
    return {**row, 'user': Session(vm, '/tmp').metadata['user'], 'client_id': hashlib.sha256(str(vm.resolve()).encode()).hexdigest()}


def install_client(session):
    if (session.vm / 'uvm.lock.json').exists():
        available = files.agent(session, 'command -v mount.nfs >/dev/null && echo ready || echo missing').strip()
        if available != 'ready': raise ValueError('provision the sharing profile in this locked environment before connecting; no packages were changed')
    path = '/usr/local/lib/ubuntu-vm/shared-files-client.py'
    files.agent(session, 'install -d /usr/local/lib/ubuntu-vm')
    files.upload(session, (rt.ROOT / 'src/ubuntu/guest/shared-files-client.py').read_bytes(), path)
    files.agent(session, 'chmod 755 ' + path)


def guest(session, action, row):
    command = 'nsenter --target 1 --mount --net -- python3 /usr/local/lib/ubuntu-vm/shared-files-client.py ' + action + ' ' + shlex.quote(json.dumps(guest_config(session.vm, row)))
    return files.agent(session, command, timeout=600)


def attach(vm, identity, qga):
    from supervisor import free_port
    _, record, share, server = descriptor(vm, identity)
    session = Session(vm, '/tmp', qga)
    session.ensure()
    install_client(session)
    if any(row['id'] == identity for row in clients(vm)):
        pid = start_watch(vm, qga)
        wait_ready(vm, pid)
        return
    with volumes.locked(vm):
        rows = clients(vm)
        if len(rows) >= 16: raise ValueError('at most 16 shared folders per VM')
        used = {row['port'] for row in rows}
        port = free_port()
        while port in used: port = free_port()
        name = re.sub(r'[^A-Za-z0-9 _.-]', '-', record['name']).strip(' .-')[:40] or 'Shared'
        name = name.replace('..', '-') + '-' + identity[:6]
        rows.append({'id': identity, 'port': port, 'folder': name})
        # Persistent guest registration is written before enabling its boot
        # gate. Mounting itself waits for the authenticated reverse tunnel.
        row = rows[-1]
        files.agent(session, 'python3 /usr/local/lib/ubuntu-vm/shared-files-client.py register-only ' + shlex.quote(json.dumps(guest_config(vm, row))), timeout=900)
        write_json(vm / CLIENTS, {'schema': 1, 'folders': rows})
        _, _, share, _ = descriptor(vm, identity)
        if str(vm) not in share['clients']: share['clients'].append(str(vm))
        write_json(volumes.store(vm) / identity / 'sharing.json', share)
    pid = start_watch(vm, qga)
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        status = vm / 'logs/shared-status.json'
        if status.exists():
            state = volumes.read(status)
            if state.get('pid') == pid and identity in state.get('mounted', []):
                print('Ready: /home/' + session.metadata['user'] + '/Shared/' + row['folder'], flush=True)
                return
        time.sleep(.5)
    raise TimeoutError('the shared folder did not become ready; see logs/shared-folders.log')


def remove(vm, identity, qga):
    session = Session(vm, '/tmp', qga)
    session.ensure()
    rows = clients(vm)
    row = next((row for row in rows if row['id'] == identity), None)
    if not row: return
    with client_locked(vm):
        guest(session, 'remove', row)  # Refuses a busy mount; never force-unmount data.
        write_json(vm / CLIENTS, {'schema': 1, 'folders': [row for row in rows if row['id'] != identity]})
        with volumes.locked(vm):
            folder, _, share, _ = descriptor(vm, identity)
            share['clients'] = [path for path in share['clients'] if path != str(vm)]
            write_json(folder / 'sharing.json', share)


def start_watch(vm, qga=None, pid=None):
    if not clients(vm): return
    if pid is None:
        state = rt.live(vm)
        if state: pid = state['qemu_pid']
        else:
            output = subprocess.run(['lsof', '-t', str(vm / 'disk.img')], capture_output=True, text=True, check=True).stdout.split()
            if len(output) != 1: raise ValueError('could not identify the running VM')
            pid = int(output[0])
    args = [sys.executable, str(rt.ROOT / 'src/dev/uvm.py'), 'sharing', '--vm', str(vm), 'watch', '--pid', str(pid)]
    if qga: args += ['--qga', str(qga)]
    with open(rt.private_dir(vm / 'logs') / 'shared-folders.log', 'ab') as log:
        subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    return pid


def wait_ready(vm, pid, timeout=180):
    expected = {row['id'] for row in clients(vm)}
    if not expected: return
    deadline = time.monotonic() + timeout
    last = 'waiting for the private file connection'
    while time.monotonic() < deadline:
        file = vm / 'logs/shared-status.json'
        if file.exists():
            state = volumes.read(file)
            if state.get('pid') == pid and expected.issubset(state.get('mounted', [])): return
            last = state.get('error') or last
        time.sleep(.5)
    raise TimeoutError('shared folders are not ready: ' + last)


def root_ssh(session):
    # QGA is the private channel used elsewhere to pin a VM's SSH host key.
    public = files.agent(session, 'cat /etc/ssh/ssh_host_ed25519_key.pub').strip()
    network.public_keys(public)
    if not public.startswith('ssh-ed25519 '): raise ValueError('invalid SSH host identity')
    known = session.vm / 'shared-known_hosts'
    text = f'[127.0.0.1]:{session.metadata["ssh_port"]} ' + ' '.join(public.split()[:2]) + '\n'
    if known.exists() and known.read_text() != text: raise ValueError('shared connection SSH host identity changed; verify this VM first')
    known.write_text(text); known.chmod(0o600)
    return ['ssh', '-F', '/dev/null', '-i', str(session.vm / 'ssh-key'), '-p', str(session.metadata['ssh_port']),
            '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3', '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + shlex.quote(str(known)), 'root@127.0.0.1']


def watch(vm, qga, pid):
    session = Session(vm, '/tmp', qga)
    if not session.managed and qga is None: raise ValueError('desktop guest-agent socket is required')
    root = rt.sockets(vm)
    with open(root / 'shared-watch.lock', 'a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        control = str(root / 'shared-ssh')
        master = None
        forwarded = {}
        status = vm / 'logs/shared-status.json'
        write_json(status, {'schema': 1, 'pid': pid, 'mounted': [], 'error': None})
        installed = False
        checked = {}
        disk = 'file=' + str(vm / 'disk.img').replace(',', ',,') + ','
        try:
            while True:
                process = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True)
                if process.returncode: return
                if disk not in process.stdout:
                    raw = process.stdout.partition('-drive if=none,id=disk,file=')[2].partition(',format=raw')[0]
                    if not raw or Path(raw.replace(',,', ',')).resolve() != (vm / 'disk.img').resolve(): return
                mounted = []
                try:
                    rows = clients(vm)
                    if not rows: return
                    if (vm / 'fork-identity').exists():
                        time.sleep(.5); continue
                    if master is None or master.poll() is not None:
                        forwarded.clear()
                        checked.clear()
                        installed = False
                        Path(control).unlink(missing_ok=True)
                        ssh = root_ssh(session)
                        master = subprocess.Popen(ssh[:-1] + ['-M', '-S', control, '-N', '-o', 'ExitOnForwardFailure=yes', ssh[-1]], stdout=subprocess.DEVNULL)
                        for _ in range(40):
                            if master.poll() is not None: raise RuntimeError('private SSH connection failed')
                            check = subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'check', ssh[-1]], capture_output=True)
                            if check.returncode == 0: break
                            time.sleep(.25)
                        else: raise RuntimeError('private SSH connection did not become ready')
                    if not installed:
                        install_client(session)
                        for row in rows: guest(session, 'register-only', row)
                        installed = True
                    for identity in set(forwarded) - {row['id'] for row in rows}:
                        subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'cancel', '-R', forwarded.pop(identity), 'root@127.0.0.1'], capture_output=True, check=True)
                    for row in rows:
                        _, _, share, server = descriptor(vm, row['id'])
                        server_tunnel(server, share)
                        if row['id'] not in forwarded:
                            mapping = f'127.0.0.1:{row["port"]}:127.0.0.1:{share["nfs_port"]}'
                            subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'forward', '-R', mapping, 'root@127.0.0.1'], capture_output=True, check=True, timeout=15)
                            forwarded[row['id']] = mapping
                        if row['id'] not in checked or time.monotonic() - checked[row['id']] >= 30:
                            with client_locked(vm):
                                if row['id'] not in {current['id'] for current in clients(vm)}: continue
                                guest(session, 'mount', row)
                                checked[row['id']] = time.monotonic()
                        mounted.append(row['id'])
                    write_json(status, {'schema': 1, 'pid': pid, 'mounted': mounted, 'error': None})
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    write_json(status, {'schema': 1, 'pid': pid, 'mounted': mounted, 'error': str(error)[-2000:]})
                time.sleep(3)
        finally:
            if master and master.poll() is None:
                master.terminate()
                try: master.wait(timeout=10)
                except subprocess.TimeoutExpired: master.kill(); master.wait()
            write_json(status, {'schema': 1, 'pid': pid, 'mounted': [], 'error': None})


def connect(vm, identity):
    _, _, _, server = descriptor(vm, identity)
    rt.ensure_up(server)
    return files.connect(Session(server, '/tmp'))


def stop(vm, identity):
    _, _, share, server = descriptor(vm, identity)
    for client in share['clients']:
        if Path(client).exists(): volumes.idle(Path(client))
    rt.stop(server)


def main(args):
    from checkpoints import validate_vm
    vm = validate_vm(args.vm)
    if args.action == 'list': result = listing(vm)
    elif args.action == 'create': result = create(vm, args.id, args.name or '', args.size_gb, sys.stdin.buffer.read(1025).decode().rstrip('\n'))
    elif args.action == 'use': attach(vm, args.id or '', args.qga); result = {'ready': True}
    elif args.action == 'remove': remove(vm, args.id or '', args.qga); result = {'removed': True}
    elif args.action == 'connect': result = connect(vm, args.id or '')
    elif args.action == 'stop': stop(vm, args.id or ''); result = {'stopped': True}
    else:
        if not args.pid or args.pid < 1: raise ValueError('a running QEMU process is required')
        watch(vm, args.qga, args.pid); return 0
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: json.dump(result, stream)
    else: print(json.dumps(result))
    return 0
