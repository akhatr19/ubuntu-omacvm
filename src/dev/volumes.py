"""Personal ext4 disks live outside VM folders, with one writable attachment."""
import base64
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid

from manifest import write_json
import runtime as rt

BINDING = 'data-volume.json'
FOLDERS = ('Projects', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')


def library(vm):
    parent = Path(vm).resolve().parent
    return parent.parent if parent.name == '.ubuntu-services' else parent


def store(vm):
    return rt.private_dir(library(vm) / '.ubuntu-data')


@contextlib.contextmanager
def locked(vm):
    descriptor = os.open(store(vm) / 'registry.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('another data operation is running; wait for it to finish')
        yield


def read(path):
    if path.is_symlink() or path.stat().st_size > 16384:
        raise ValueError('invalid personal data metadata')
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get('schema') != 1:
        raise ValueError('unsupported personal data metadata')
    return value


def volume(vm, identity):
    if not isinstance(identity, str) or not re.fullmatch(r'[0-9a-f]{32}', identity):
        raise ValueError('invalid personal data ID')
    folder = store(vm) / identity
    if folder.is_symlink(): raise ValueError('data folder is a symlink')
    record = read(folder / 'volume.json')
    disk = folder / 'data.img'
    if record.get('id') != identity or disk.is_symlink() or not disk.is_file():
        raise ValueError('personal data disk is missing or invalid; it was not replaced')
    if type(record.get('size_gb')) is not int or not 4 <= record['size_gb'] <= 4096 or disk.stat().st_size != record['size_gb'] * 1024 ** 3:
        raise ValueError('personal data disk size differs from its metadata')
    owner = record.get('attached_vm')
    if owner is not None and (not isinstance(owner, str) or Path(owner).resolve().parent not in (library(vm), library(vm) / '.ubuntu-services')):
        raise ValueError('invalid personal data owner')
    if owner is not None: record['attached_vm'] = str(Path(owner).resolve())
    return folder, record


def attached(vm, ready=True):
    file = Path(vm) / BINDING
    if not file.exists() and not file.is_symlink(): return None
    binding = read(file)
    folder, record = volume(vm, binding.get('id'))
    if record.get('attached_vm') != str(Path(vm).resolve()):
        raise ValueError('personal data ownership changed; attach the disk again')
    if ready and (binding.get('ready') is not True or (Path(vm) / 'data-needs-setup').exists()):
        raise ValueError('finish personal data setup in Workbench → Files before starting this VM')
    return folder, record


def arguments(vm, ready=True):
    found = attached(vm, ready)
    if not found: return []
    folder, record = found
    disk = str(folder / 'data.img').replace(',', ',,')
    return ['-drive', f'if=none,id=personal,file={disk},format=raw,cache=writeback,discard=unmap',
            '-device', 'virtio-blk-pci,drive=personal,serial=UVM' + record['id'][:16],
            '-smbios', 'type=11,value=uvm.data=' + record['id']]


def idle(vm, data=None):
    processes = subprocess.run(['ps', '-axo', 'args='], capture_output=True, text=True, check=True).stdout
    disk_arg = 'file=' + str(Path(vm) / 'disk.img').replace(',', ',,') + ','
    if disk_arg in processes or rt.disk_busy(Path(vm)) or rt.live(Path(vm)):
        raise ValueError('stop the VM before changing personal data')
    if data:
        result = subprocess.run(['lsof', '-t', str(data)], capture_output=True, text=True)
        if result.returncode not in (0, 1) or result.stdout.strip():
            raise ValueError('personal data disk is in use; stop its VM first')


def label(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 80 or any(ord(c) < 32 for c in value):
        raise ValueError('use a data name of 1–80 characters')
    return value.strip()


def create(vm, name, size):
    name = label(name)
    if type(size) is not int or not 4 <= size <= 4096: raise ValueError('choose a data disk size of 4–4096 GB')
    identity = uuid.uuid4().hex
    folder = rt.private_dir(store(vm) / identity)
    try:
        with open(folder / 'data.img', 'xb') as stream:
            stream.truncate(size * 1024 ** 3)
        (folder / 'data.img').chmod(0o600)
        record = {'schema': 1, 'id': identity, 'name': name, 'size_gb': size, 'initialized': False,
                  'attached_vm': None, 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        write_json(folder / 'volume.json', record)
        return record
    except BaseException:
        shutil.rmtree(folder)
        raise


def listing(vm):
    rows = []
    for path in store(vm).iterdir():
        if re.fullmatch(r'[0-9a-f]{32}', path.name):
            folder, record = volume(vm, path.name)
            rows.append({**record, 'allocated_bytes': (folder / 'data.img').stat().st_blocks * 512})
        if len(rows) > 1024: raise ValueError('too many personal data disks')
    binding = read(Path(vm) / BINDING) if (Path(vm) / BINDING).exists() else {}
    return {'volumes': sorted(rows, key=lambda row: row['name']), 'attached': binding.get('id'), 'folders': binding.get('folders', list(FOLDERS))}


def maintenance(vm, script, data_args):
    """A private maintenance boot: no GUI, no networking or Mac folders exposed."""
    resources = rt.app_bundle() / 'Contents/Resources'
    with tempfile.TemporaryDirectory(prefix='uvm-data-', dir='/tmp') as directory:
        socket = Path(directory) / 'qga'
        q = lambda path: str(path).replace(',', ',,')
        args = [resources / 'runtime/bin/OmacVM', '-machine', 'virt,gic-version=3', '-accel', 'hvf',
                '-cpu', 'host,pmu=off', '-smp', '2', '-m', '2048', '-nodefaults', '-display', 'none',
                '-action', 'reboot=reset,shutdown=poweroff', '-boot', 'menu=off',
                '-drive', f'if=pflash,format=raw,readonly=on,file={q(resources / "firmware/edk2-aarch64-code.fd")}',
                '-drive', f'if=pflash,format=raw,file={q(vm / "efi-vars.fd")}',
                '-drive', f'if=none,id=disk,file={q(vm / "disk.img")},format=raw,discard=unmap',
                '-device', 'nvme,serial=omacvm,drive=disk,bootindex=0',
                '-device', 'virtio-rng-pci', '-device', 'virtio-serial-pci',
                '-chardev', f'socket,id=qga,path={socket},server=on,wait=off',
                '-device', 'virtserialport,chardev=qga,name=org.qemu.guest_agent.0',
                '-serial', f'file:{q(vm / "logs/data-maintenance.log")}'] + data_args
        rt.private_dir(vm / 'logs')
        with open(vm / 'logs/data-maintenance-qemu.log', 'ab') as log:
            process = subprocess.Popen([str(a) for a in args], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if process.poll() is not None: raise RuntimeError('maintenance boot failed; see logs/data-maintenance-qemu.log')
                    try:
                        rt.socket_request(socket, 'guest-ping', qga=True)
                        break
                    except (OSError, ValueError, RuntimeError): time.sleep(.5)
                else: raise TimeoutError('maintenance guest agent did not answer')
                # Reuse the bounded guest-exec implementation without SSH or app launch.
                from files import agent
                from types import SimpleNamespace
                session = SimpleNamespace(vm=vm, managed=False, qga=socket)
                guest_path = '/run/ubuntu-vm-data-' + uuid.uuid4().hex + '.sh'
                payload = ('set -e\nif systemctl cat display-manager.service >/dev/null 2>&1; then systemctl stop display-manager.service; fi\n' + script).encode()
                handle = rt.socket_request(socket, 'guest-file-open', {'path': guest_path, 'mode': 'w'}, qga=True)
                try:
                    for offset in range(0, len(payload), 1024):
                        block = payload[offset:offset + 1024]
                        written = rt.socket_request(socket, 'guest-file-write', {'handle': handle, 'buf-b64': base64.b64encode(block).decode()}, qga=True)
                        if written.get('count') != len(block): raise RuntimeError('guest did not accept the complete data setup script')
                    rt.socket_request(socket, 'guest-file-flush', {'handle': handle}, qga=True)
                finally:
                    rt.socket_request(socket, 'guest-file-close', {'handle': handle}, qga=True)
                result = agent(session, 'set -e; trap ' + shlex.quote('rm -f ' + guest_path) + ' EXIT; chmod 600 ' + guest_path + '; bash ' + guest_path, timeout=900)
                try:
                    agent(session, 'sync; systemctl poweroff --no-block', timeout=15)
                except (OSError, RuntimeError, TimeoutError):
                    pass  # Shutdown can close QGA before its final exec status.
                process.wait(timeout=90)
                if process.returncode: raise RuntimeError('maintenance VM did not shut down cleanly')
                return result
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()


def guest_script(settings, mode):
    source = (rt.ROOT / 'src/ubuntu/guest/personal-data.py').read_bytes()
    payload = base64.b64encode(source).decode()
    path = '/usr/local/lib/ubuntu-vm/personal-data.py'
    return ('set -e\ninstall -d /usr/local/lib/ubuntu-vm\n'
            + 'printf %s ' + shlex.quote(payload) + ' | base64 -d > ' + path + '\n'
            + 'chmod 755 ' + path + '\npython3 ' + path + ' ' + shlex.quote(json.dumps(settings)) + ' ' + mode)


def prepare(vm, identity, folders):
    vm = Path(vm).resolve()
    folder, record = volume(vm, identity)
    if not folders or any(name not in FOLDERS for name in folders) or len(set(folders)) != len(folders):
        raise ValueError('select supported personal folders')
    from workspace import Session
    user = Session(vm, '/tmp').metadata['user']
    old_owner = Path(record['attached_vm']) if record.get('attached_vm') else None
    idle(vm, folder / 'data.img')
    current = attached(vm, ready=False)
    if current and current[1]['id'] != identity: raise ValueError('detach the current data disk first')
    if record.get('shared') and old_owner != vm:
        raise ValueError('this disk backs a shared folder; use Shared Folders instead of attaching it directly')
    if old_owner and old_owner != vm and old_owner.exists():
        idle(old_owner, folder / 'data.img')
        print('Releasing personal data from ' + old_owner.name + '…', flush=True)
        detach(old_owner)
        folder, record = volume(vm, identity)
    recover = not record['initialized'] and record.get('setup_started')
    record.update(attached_vm=str(vm), setup_started=True)
    write_json(folder / 'volume.json', record)
    write_json(vm / BINDING, {'schema': 1, 'id': identity, 'ready': False, 'folders': folders})
    settings = {'schema': 1, 'id': identity, 'user': user, 'folders': folders, 'filesystem_id': record.get('filesystem_id', identity)}
    mode = 'recover' if recover else ('attach' if record['initialized'] else 'initialize')
    script = guest_script(settings, mode)
    print('Preparing personal data in a private maintenance boot…', flush=True)
    maintenance(vm, script, arguments(vm, ready=False))
    record.update(initialized=True, setup_started=False)
    write_json(folder / 'volume.json', record)
    write_json(vm / BINDING, {'schema': 1, 'id': identity, 'ready': True, 'folders': folders})
    (vm / 'data-needs-setup').unlink(missing_ok=True)
    return record


def detach(vm):
    vm = Path(vm).resolve()
    found = attached(vm, ready=False)
    if not found: return {'detached': None}
    folder, record = found
    idle(vm, folder / 'data.img')
    print('Restoring this distro’s local folders in a maintenance boot…', flush=True)
    maintenance(vm, guest_script({}, 'detach'), [])
    (vm / BINDING).unlink()
    (vm / 'data-needs-setup').unlink(missing_ok=True)
    record['attached_vm'] = None
    write_json(folder / 'volume.json', record)
    return {'detached': record['id']}


def snapshot(vm, identity, name):
    from bundles import copy_disk
    folder, record = volume(vm, identity)
    owner = Path(record['attached_vm']) if record.get('attached_vm') else vm
    idle(owner, folder / 'data.img')
    if not record['initialized']: raise ValueError('finish data setup before snapshotting')
    name = label(name)
    stamp = uuid.uuid4().hex
    target = rt.private_dir(folder / 'snapshots') / stamp
    target.mkdir(mode=0o700)
    try:
        with open(folder / 'data.img', 'r+b') as disk:
            try:
                fcntl.lockf(disk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('personal data disk is locked by a running VM')
            os.fsync(disk.fileno())
            copy_disk(folder / 'data.img', target / 'data.img')
        saved = {**record, 'snapshot_id': stamp, 'snapshot_name': name, 'attached_vm': None}
        write_json(target / 'snapshot.json', saved)
        (target / 'data.img').chmod(0o400)
        return saved
    except BaseException:
        shutil.rmtree(target); raise


def snapshots(vm, identity):
    folder, _ = volume(vm, identity)
    root = folder / 'snapshots'
    rows = []
    if root.is_dir():
        for path in root.iterdir():
            if re.fullmatch(r'[0-9a-f]{32}', path.name): rows.append(read(path / 'snapshot.json'))
            if len(rows) > 4096: raise ValueError('too many data snapshots')
    return rows


def fork(vm, identity, snapshot_id, name):
    from bundles import copy_disk
    folder, record = volume(vm, identity)
    if not re.fullmatch(r'[0-9a-f]{32}', snapshot_id): raise ValueError('invalid data snapshot ID')
    source = folder / 'snapshots' / snapshot_id
    saved = read(source / 'snapshot.json')
    if saved.get('snapshot_id') != snapshot_id or saved.get('id') != identity or (source / 'data.img').is_symlink():
        raise ValueError('invalid data snapshot')
    # Preserve the ext4 UUID; only one disk with that UUID may be in a guest.
    # QEMU serial and ownership use the new independent identity.
    child = create(vm, name, record['size_gb'])
    target, _ = volume(vm, child['id'])
    try:
        (target / 'data.img').unlink()
        copy_disk(source / 'data.img', target / 'data.img')
        child.update(initialized=True, filesystem_id=saved.get('filesystem_id', identity), parent_snapshot=snapshot_id)
        write_json(target / 'volume.json', child)
        return child
    except BaseException:
        shutil.rmtree(target); raise


def restore(vm, identity, snapshot_id):
    from bundles import copy_disk
    folder, record = volume(vm, identity)
    if record.get('attached_vm'): raise ValueError('detach personal data before restoring it')
    idle(vm, folder / 'data.img')
    if not re.fullmatch(r'[0-9a-f]{32}', snapshot_id): raise ValueError('invalid data snapshot ID')
    source = folder / 'snapshots' / snapshot_id
    saved = read(source / 'snapshot.json')
    if saved.get('snapshot_id') != snapshot_id or saved.get('id') != identity or (source / 'data.img').is_symlink():
        raise ValueError('invalid data snapshot')
    preserved = snapshot(vm, identity, 'Before data restore')
    temporary = folder / ('.restoring-' + uuid.uuid4().hex)
    try:
        copy_disk(source / 'data.img', temporary)
        with open(temporary, 'rb') as stream: os.fsync(stream.fileno())
        os.replace(temporary, folder / 'data.img')
        return {'restored': snapshot_id, 'preserved': preserved['snapshot_id']}
    finally: temporary.unlink(missing_ok=True)


def main(args):
    from checkpoints import validate_vm
    vm = validate_vm(args.vm)
    from guests import profile
    if profile(vm) != 'ubuntu':
        raise ValueError('Linux-backed data disks currently require an Ubuntu VM; use shared home folders for Omarchy')
    with locked(vm):
        if args.action == 'list': result = listing(vm)
        elif args.action == 'create': result = create(vm, args.name or '', args.size_gb)
        elif args.action == 'attach': result = prepare(vm, args.id or '', args.folder or list(FOLDERS))
        elif args.action == 'detach': result = detach(vm)
        elif args.action == 'snapshot': result = snapshot(vm, args.id or '', args.name or '')
        elif args.action == 'snapshots': result = {'snapshots': snapshots(vm, args.id or '')}
        elif args.action == 'restore': result = restore(vm, args.id or '', args.snapshot_id or '')
        else: result = fork(vm, args.id or '', args.snapshot_id or '', args.name or '')
    if args.output:
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream: json.dump(result, stream)
        print('Personal data ready.')
    else: print(json.dumps(result))
    return 0
