"""Finder's authenticated SMB drive over private SSH, and directional file sync."""
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid

from manifest import write_json
import runtime as rt
from supervisor import free_port
from workspace import Session


def agent(session, command, data=None, timeout=600):
    import base64
    import time
    path = rt.sockets(session.vm) / 'qga' if session.managed else session.qga
    request = {'path': '/bin/bash', 'arg': ['-c', command], 'capture-output': True}
    if data is not None: request['input-data'] = base64.b64encode(data).decode()
    pid = rt.socket_request(path, 'guest-exec', request, qga=True)['pid']
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        reply = rt.socket_request(path, 'guest-exec-status', {'pid': pid}, qga=True)
        if reply.get('exited'):
            output = base64.b64decode(reply.get('out-data', '')).decode(errors='replace')
            error = base64.b64decode(reply.get('err-data', '')).decode(errors='replace')
            if reply.get('exitcode') != 0:
                raise RuntimeError('Ubuntu file service failed: ' + error[-3000:])
            return output
        time.sleep(.5)
    raise TimeoutError('Ubuntu file service is still installing; wait for its package operation to finish')


def setup(session, password):
    if not 8 <= len(password) <= 256 or any(c in password for c in '\r\n\0'):
        raise ValueError('choose a sharing password of 8–256 characters, without line breaks')
    user = session.metadata['user']
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user): raise ValueError('invalid Ubuntu user')
    source = (rt.ROOT / 'src/ubuntu/guest/file-sharing.sh').read_text()
    # Script arguments contain only the account name. The password is stdin,
    # never a command-line argument, saved host file or console message.
    agent(session, 'U=' + shlex.quote(user) + '\n' + source, (password + '\n').encode(), timeout=900)
    file = session.vm / 'finder-drive.json'
    old = json.loads(file.read_text()) if file.is_file() and not file.is_symlink() and file.stat().st_size <= 8192 else {}
    port = old.get('port')
    state = {'schema': 1, 'user': user, 'port': port if type(port) is int and 1024 <= port <= 65535 else free_port()}
    write_json(file, state); file.chmod(0o600)
    return state


def connect(session):
    state_file = session.vm / 'finder-drive.json'
    if not state_file.exists(): raise ValueError('enable Finder sharing and choose its password first')
    if state_file.is_symlink() or state_file.stat().st_size > 8192: raise ValueError('invalid Finder settings')
    state = json.loads(state_file.read_text())
    if state.get('schema') != 1 or state.get('user') != session.metadata['user'] or type(state.get('port')) is not int or not 1024 <= state['port'] <= 65535:
        raise ValueError('invalid Finder settings')
    control = str(rt.sockets(session.vm) / 'finder-ssh')
    destination = session.ssh()[-1]
    check = subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'check', destination], capture_output=True, text=True)
    if check.returncode:
        Path(control).unlink(missing_ok=True)
        args = session.ssh()[:-1] + ['-M', '-S', control, '-f', '-N', '-o', 'ExitOnForwardFailure=yes',
                '-L', f'127.0.0.1:{state["port"]}:127.0.0.1:1445', destination]
        subprocess.run(args, check=True, timeout=30)
        write_json(state_file, state); state_file.chmod(0o600)
        check = subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'check', destination], capture_output=True, text=True)
    pid = re.search(r'pid=(\d+)', check.stderr)
    if pid:
        (rt.private_dir(rt.sockets(session.vm) / 'leases') / pid.group(1)).touch(mode=0o600)
    return state


def sync(session, local, direction, preview):
    if not local: raise ValueError('choose a Mac folder')
    local = Path(local).expanduser().resolve()
    home = Path.home().resolve()
    if local == home or local in home.parents or local == Path('/') or not local.is_dir():
        raise ValueError('choose an existing Mac data folder, not your entire home or a parent')
    # rsync is installed explicitly as a file-service prerequisite. Snapshotted
    # environments should include the Files profile when provisioning their lock.
    session.run(['rsync', '--version'], capture=True)
    target = session.ssh()[-1] + ':' + shlex.quote(session.project.rstrip('/') + '/')
    local_path = str(local) + '/'
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    if direction == 'to-linux':
        backup = f'/home/{session.metadata["user"]}/.local/share/ubuntu-vm/sync-backups/{stamp}'
        if not preview: session.run(['mkdir', '-p', '-m', '700', '--', backup, session.project])
        source, destination = local_path, target
    else:
        backup = str(rt.private_dir(rt.HOME / 'sync-backups' / stamp)) if not preview else str(rt.HOME / 'sync-backups' / stamp)
        source, destination = target, local_path
    command = ['/usr/bin/rsync', '-rltu', '--safe-links', '--checksum', '--itemize-changes', '--backup', '--backup-dir=' + backup,
               '--exclude=.DS_Store', '--exclude=node_modules', '--exclude=.venv', '--timeout=60', '-e', shlex.join(session.ssh()[:-1])]
    if preview: command.append('--dry-run')
    subprocess.run(command + ['--', source, destination], check=True)
    print('Preview only; no files changed.' if preview else 'Sync complete. Replaced-file backups: ' + backup)
    print('Newer destination files were kept. No destination files were deleted.')


def main(args):
    session = Session(args.vm, args.project, args.qga)
    if args.action != 'disconnect': session.ensure()
    if args.action == 'enable':
        print('Installing authenticated file sharing in Ubuntu…', flush=True)
        setup(session, sys.stdin.buffer.read(1025).decode().rstrip('\n'))
        print(json.dumps(connect(session)))
    elif args.action == 'connect': print(json.dumps(connect(session)))
    elif args.action == 'sync': sync(session, args.local, args.direction, args.preview)
    elif args.action == 'disconnect':
        control = str(rt.sockets(session.vm) / 'finder-ssh')
        subprocess.run(['ssh', '-F', '/dev/null', '-S', control, '-O', 'exit', session.metadata['user'] + '@127.0.0.1'], check=False)
    return 0
