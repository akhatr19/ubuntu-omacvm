"""Stopped-disk checkpoints and independent forks. Mac shared data stays external."""
import contextlib
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

from bundles import copy_disk
from manifest import write_json
import network
import runtime as rt
from supervisor import free_port

RECORD = 'checkpoint-head.json'
SKIP = {'logs', RECORD, 'workspace-known_hosts', 'developer-network-status', 'update.log'}


def read_json(path):
    if path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise ValueError('invalid checkpoint metadata')
    return json.loads(path.read_text())


def validate_vm(vm):
    vm = Path(vm).resolve()
    if '.ubuntu-checkpoints' in vm.parts:
        raise ValueError('checkpoint storage is immutable; fork it into a VM first')
    if (vm / 'guest-os').read_text().strip() != 'ubuntu' or not (vm / 'disk.img').is_file() or (vm / 'disk.img').is_symlink():
        raise ValueError('select an Ubuntu VM')
    if os.environ.get('UVM_TEST_MODE') == '1' and not vm.name.startswith('OmacVM Test-'):
        raise ValueError('test mode refuses a personal VM')
    return vm


def store(vm):
    return rt.private_dir(vm.parent / '.ubuntu-checkpoints')


def head(vm):
    path = vm / RECORD
    return read_json(path) if path.exists() else {'schema': 1, 'lineage': uuid.uuid4().hex, 'branch': uuid.uuid4().hex, 'parent': None}


def checkpoint(vm, identity):
    if not re.fullmatch(r'[0-9a-f]{32}', identity):
        raise ValueError('invalid checkpoint ID')
    folder = store(vm) / identity
    record = read_json(folder / 'checkpoint.json')
    if record.get('id') != identity or record.get('schema') != 1:
        raise ValueError('invalid checkpoint')
    return folder, record


@contextlib.contextmanager
def stopped(vm):
    # The disk lock coordinates with QEMU; the owner lock coordinates with the
    # developer supervisor so no cold start can race a restore or checkpoint.
    with open(rt.sockets(vm) / 'owner.lock', 'a') as owner, open(vm / 'disk.img', 'r+b') as disk:
        try:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.lockf(disk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('stop this VM before checkpointing, restoring or forking')
        if rt.disk_busy(vm):
            # lsof sees this process's descriptor too: exclude only ourselves.
            import subprocess
            pids = subprocess.run(['lsof', '-t', str(vm / 'disk.img')], capture_output=True, text=True).stdout.split()
            if any(pid != str(os.getpid()) for pid in pids):
                raise ValueError('this VM disk is in use; stop it first')
        os.fsync(disk.fileno())
        yield


def exchange(first, second):
    # macOS's atomic directory exchange keeps the VM path valid even if the
    # host loses power. Never fall back to two non-atomic directory renames.
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    swap = library.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(first), os.fsencode(second), 2) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, 'filesystem cannot atomically exchange VM folders')


def copy_tree(source, destination):
    destination.mkdir(mode=0o700)
    for path in source.iterdir():
        if path.name in SKIP or path.name.startswith('.'):
            continue
        if path.is_symlink():
            raise ValueError('VM contains a symlink; checkpoints never follow external data: ' + path.name)
        target = destination / path.name
        if path.is_dir():
            # Only the locked provisioning definition is needed from subfolders.
            if path.name == 'definition':
                for item in path.rglob('*'):
                    if item.is_symlink():
                        raise ValueError('definition contains an external symlink')
                shutil.copytree(path, target)
        elif path.name in ('disk.img', 'efi-vars.fd'):
            copy_disk(path, target)
        elif path.is_file():
            if path.stat().st_size > 1024 * 1024:
                continue
            shutil.copyfile(path, target); target.chmod(0o600)


def create_locked(vm, label):
    if not label.strip() or len(label) > 100 or any(ord(c) < 32 for c in label):
        raise ValueError('use a checkpoint name of 1–100 characters')
    parent = head(vm)
    identity = uuid.uuid4().hex
    root = store(vm)
    temporary = Path(tempfile.mkdtemp(prefix='.creating-', dir=root))
    try:
        copy_tree(vm, temporary / 'vm')
        record = {'schema': 1, 'id': identity, 'parent': parent['parent'], 'lineage': parent['lineage'],
                  'label': label, 'vm_name': vm.name, 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'branch': parent['branch'], 'kind': 'stopped-disk', 'runtime_sha256': rt.runtime_identity(),
                  'external_mac_data': 'excluded', 'ram': 'not included'}
        write_json(temporary / 'checkpoint.json', record)
        for path in temporary.rglob('*'):
            if path.is_file(): path.chmod(0o400)
        temporary.rename(root / identity)
        write_json(vm / RECORD, {'schema': 1, 'lineage': parent['lineage'], 'branch': parent['branch'], 'parent': identity})
        return record
    finally:
        if temporary.exists(): shutil.rmtree(temporary)


def create(vm, label):
    vm = validate_vm(vm)
    with stopped(vm):
        return create_locked(vm, label)


def listing(vm):
    vm = validate_vm(vm)
    state = head(vm)
    entries = []
    for folder in store(vm).iterdir():
        if re.fullmatch(r'[0-9a-f]{32}', folder.name):
            record = read_json(folder / 'checkpoint.json')
            if record.get('lineage') == state['lineage']:
                entries.append(record)
            if len(entries) > 4096: raise ValueError('too many checkpoints to list')
    return {'head': state.get('parent'), 'checkpoints': sorted(entries, key=lambda row: row['created_at'], reverse=True)}


def restore(vm, identity):
    vm = validate_vm(vm)
    folder, record = checkpoint(vm, identity)
    current = head(vm)
    if record['lineage'] != current['lineage']:
        raise ValueError('checkpoint belongs to another VM lineage')
    if record['runtime_sha256'] != rt.runtime_identity():
        raise ValueError('checkpoint requires its original QEMU runtime')
    with stopped(vm):
        local_env = (vm / 'vm.env').read_text()
        local_metadata = read_json(vm / 'uvm-env.json') if (vm / 'uvm-env.json').exists() else None
        preserved = create_locked(vm, 'Before restore of ' + record['label'][:70])
        temporary = Path(tempfile.mkdtemp(prefix='.restoring-', dir=vm.parent))
        try:
            copy_tree(folder / 'vm', temporary / 'vm')
            child = temporary / 'vm'
            # Host publication and Mac-folder grants belong to this VM, not
            # another branch's historical Linux state. Never re-enable them on restore.
            for file in ('developer-network.json', 'mac-folder', 'fast-network', 'mac-setup', 'finder-drive.json'):
                (child / file).unlink(missing_ok=True)
                if (vm / file).is_file(): shutil.copyfile(vm / file, child / file)
            restored_env = (child / 'vm.env').read_text()
            for field in ('NAME', 'SSH_PORT'):
                match = re.search(r'^' + field + r'=.*$', local_env, re.M)
                if match: restored_env = re.sub(r'^' + field + r'=.*$', lambda _: match.group(0), restored_env, flags=re.M)
            (child / 'vm.env').write_text(restored_env)
            if local_metadata:
                metadata = read_json(child / 'uvm-env.json')
                for field in ('name', 'vm_name', 'ssh_port'): metadata[field] = local_metadata[field]
                write_json(child / 'uvm-env.json', metadata)
            if record.get('branch') != current['branch']:
                for file in ('ssh-key', 'ssh-key.pub'):
                    shutil.copyfile(vm / file, child / file); (child / file).chmod(0o600)
                for file in ('identity-ready', 'known_hosts', 'workspace-known_hosts'):
                    (child / file).unlink(missing_ok=True)
                if not local_metadata: (child / 'fork-identity').write_text(uuid.uuid4().hex + '\n')
            write_json(child / RECORD, {'schema': 1, 'lineage': record['lineage'], 'branch': current['branch'], 'parent': identity})
            rt.private_dir(child / 'logs')
            exchange(child, vm)
            return {'restored': identity, 'preserved': preserved['id']}
        finally:
            shutil.rmtree(temporary, ignore_errors=True)


def fork(vm, identity, name):
    vm = validate_vm(vm)
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,39}', name):
        raise ValueError('branch name must start with a lowercase letter and use letters, digits and dashes')
    folder, record = checkpoint(vm, identity)
    if record['lineage'] != head(vm)['lineage'] or record['runtime_sha256'] != rt.runtime_identity():
        raise ValueError('checkpoint lineage or runtime does not match')
    managed = (folder / 'vm/uvm-env.json').exists()
    prefix = 'OmacVM Test-' if os.environ.get('UVM_TEST_MODE') == '1' else 'Ubuntu-'
    target = vm.parent / ((('OmacVM Test-Dev-' if os.environ.get('UVM_TEST_MODE') == '1' else 'Dev-') + name) if managed else (prefix + name))
    if target.exists(): raise ValueError('a VM with that branch name already exists')
    temporary = Path(tempfile.mkdtemp(prefix='.forking-', dir=vm.parent))
    try:
        copy_tree(folder / 'vm', temporary / 'vm')
        child = temporary / 'vm'
        port = free_port()
        reserved = {int(match.group(1)) for path in vm.parent.glob('*/vm.env')
                    for match in re.finditer(r'^SSH_PORT=(\d+)$', path.read_text(), re.M)}
        while port in reserved: port = free_port()
        text = (child / 'vm.env').read_text()
        text = re.sub(r'^NAME=.*$', "NAME='" + target.name + "'", text, flags=re.M)
        text = re.sub(r'^SSH_PORT=.*$', 'SSH_PORT=' + str(port), text, flags=re.M)
        (child / 'vm.env').write_text(text)
        for key in ('ssh-key', 'ssh-key.pub', 'known_hosts', 'workspace-known_hosts', 'identity-ready', 'mac-folder', 'mac-setup', 'fast-network', 'finder-drive.json'):
            (child / key).unlink(missing_ok=True)
        rt.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'ubuntu-branch', '-f', child / 'ssh-key'])
        settings = network.load(child, {})
        settings.update(ssh_lan=False, ports=[], auto_ports=False, public_keys='')
        write_json(child / 'developer-network.json', settings)
        if managed:
            data = read_json(child / 'uvm-env.json')
            data.update(name=name, vm_name=target.name, ssh_port=port)
            write_json(child / 'uvm-env.json', data)
        else:
            (child / 'fork-identity').write_text(uuid.uuid4().hex + '\n')
        write_json(child / RECORD, {'schema': 1, 'lineage': record['lineage'], 'branch': uuid.uuid4().hex, 'parent': identity})
        rt.private_dir(child / 'logs')
        child.rename(target)
        return {'folder': str(target), 'parent': identity}
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
