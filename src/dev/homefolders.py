"""Mac-owned ~/Linux folders mounted at the normal locations in each Linux home."""
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import time

from manifest import write_json
import runtime as rt

DEFAULTS = ['Desktop', 'Documents', 'Downloads']
OFF = 'home-folders-off'


def names(value):
    if not isinstance(value, list) or len(value) > 16 or any(
            not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 _-]{0,63}', name) for name in value):
        raise ValueError('choose up to 16 simple folder names, without dots or slashes')
    if len({name.lower() for name in value}) != len(value):
        raise ValueError('folder names must be unique, including capitalization')
    if any(name.lower() in ('ubuntuvm local folders', 'mac', 'shared') for name in value):
        raise ValueError('that folder name is reserved for existing VM file access')
    return value


def settings():
    file = rt.HOME / 'home-folders.json'
    if not file.exists() and not file.is_symlink(): return list(DEFAULTS)
    if file.is_symlink() or file.stat().st_size > 4096: raise ValueError('invalid home folder settings')
    value = json.loads(file.read_text())
    if value.get('schema') != 1: raise ValueError('invalid home folder settings')
    return names(value.get('folders'))


def root():
    # Tests never create folders in the person's home.
    return rt.HOME / 'Linux' if os.environ.get('UVM_TEST_MODE') == '1' else Path.home() / 'Linux'


def enabled(vm):
    from guests import profile
    # Existing raw personal disks already mount home folders; don't cover them.
    return profile(vm) != 'custom' and not any((vm / file).exists() for file in (OFF, 'file-service', 'data-volume.json'))


def listing(vm):
    return {'schema': 1, 'root': str(root()), 'folders': settings(), 'enabled': enabled(vm),
            'personal_disk': (vm / 'data-volume.json').exists()}


def directory(path):
    if path.is_symlink(): raise ValueError(f'shared home folders must not be symbolic links: {path}')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise ValueError(f'shared home folder is not your own directory: {path}')
    with os.scandir(path): pass


def arguments(vm):
    if not enabled(vm): return []
    folders = settings()
    if not folders: return []
    directory(root())
    result = []
    for index, name in enumerate(folders):
        folder = root() / name
        directory(folder)
        path = str(folder).replace(',', ',,')
        tag = f'uvm-home-{index}'
        encoded = base64.b64encode(name.encode()).decode()
        result += ['-fsdev', f'local,id=home{index},path={path},security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000',
                   '-device', f'virtio-9p-pci,fsdev=home{index},mount_tag={tag}',
                   '-smbios', f'type=11,value=uvm.home={index}:{encoded}']
    return result


def install(vm, qga=None):
    """Install/update the boot helper through the private guest agent, without packages."""
    import files
    from workspace import Session
    session = Session(vm, '/tmp', qga)
    if qga: session.managed = False
    source = rt.ROOT / 'src/ubuntu/guest/home-folders.py'
    service = source.with_suffix('.service')
    # Keep guest-agent messages small; stage only in root-owned directories.
    for file, destination, mode in ((source, '/usr/local/bin/ubuntu-vm-home-folders', '755'),
                                    (service, '/etc/systemd/system/ubuntu-vm-home-folders.service', '644')):
        temporary = destination + '.new'
        files.upload(session, file.read_bytes(), temporary)
        files.agent(session, f'chmod {mode} {shlex.quote(temporary)}; mv {shlex.quote(temporary)} {shlex.quote(destination)}', timeout=15)
    files.agent(session, 'set -e; systemctl daemon-reload; systemctl enable --now ubuntu-vm-home-folders.service', timeout=30)


def main(args):
    from checkpoints import validate_vm, stopped
    vm = validate_vm(args.vm)
    if args.action == 'plan': result = {'arguments': arguments(vm)}
    elif args.action == 'prepare':
        directory(root())
        for name in settings(): directory(root() / name)
        result = listing(vm)
    elif args.action == 'install':
        deadline = time.monotonic() + 120
        while True:
            try:
                install(vm, args.qga); break
            except (OSError, RuntimeError, TimeoutError):
                if time.monotonic() >= deadline: raise
                time.sleep(2)
        result = {'installed': True}
    else:
        if args.action != 'list':
            rt.private_dir(rt.HOME)
            with stopped(vm), open(rt.HOME / 'home-folders.lock', 'a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                if args.action == 'enable':
                    if (vm / 'data-volume.json').exists(): raise ValueError('detach the personal disk before enabling Mac-backed home folders')
                    (vm / OFF).unlink(missing_ok=True)
                elif args.action == 'disable': (vm / OFF).touch(mode=0o600)
                else:
                    folders = settings()
                    name = args.name or ''
                    if args.action == 'add': folders = names(folders + [name])
                    else: folders = [item for item in folders if item.lower() != name.lower()]
                    write_json(rt.HOME / 'home-folders.json', {'schema': 1, 'folders': folders})
        result = listing(vm)
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: json.dump(result, stream)
    else: print(json.dumps(result))
    return 0
