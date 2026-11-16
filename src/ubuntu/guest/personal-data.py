#!/usr/bin/env python3
"""Mount a UUID-checked personal disk before login; keep local folders intact."""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import uuid

CONFIG = Path('/etc/ubuntu-vm/personal-data.json')
PROGRAM = Path('/usr/local/lib/ubuntu-vm/personal-data.py')
SERVICE = Path('/etc/systemd/system/ubuntu-vm-personal-data.service')
ROOT = Path('/mnt/ubuntu-vm-personal')
FOLDERS = ('Projects', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout.strip()


def account(config):
    user = config['user']
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user): raise ValueError('invalid data user')
    entry = pwd.getpwnam(user)
    if entry.pw_uid != 1000 or entry.pw_gid != 1000:
        raise ValueError('personal data currently requires the desktop account UID and GID to be 1000')
    home = Path(entry.pw_dir)
    if home.is_symlink() or not home.is_dir(): raise ValueError('home must be a local directory')
    if not config['folders'] or any(name not in FOLDERS for name in config['folders']): raise ValueError('invalid data folders')
    for name in config['folders']:
        path = home / name
        if path.is_symlink() or (path.exists() and not path.is_dir()): raise ValueError('personal folder is not a local directory: ' + name)
    return entry, home


def mounted(path):
    return subprocess.run(['mountpoint', '-q', str(path)]).returncode == 0


def unmount(config):
    _, home = account(config)
    for name in reversed(config['folders']):
        if mounted(home / name): run('umount', home / name)
    if mounted(ROOT): run('umount', ROOT)


def mount(config, mode='boot'):
    identity = config['id']
    if not re.fullmatch(r'[0-9a-f]{32}', identity): raise ValueError('invalid data identity')
    entry, home = account(config)
    fsid = str(uuid.UUID(config.get('filesystem_id', identity)))
    run('udevadm', 'settle', '--timeout=30')
    disk = Path('/dev/disk/by-id/virtio-UVM' + identity[:16])
    if not disk.exists():
        if mode == 'boot':
            table = Path('/sys/firmware/dmi/tables/DMI')
            expected = table.exists() and (b'uvm.data=' + identity.encode()) in table.read_bytes()
            if expected: raise ValueError('expected personal disk is unavailable; refusing to log in with local folders')
            # System forks carry local originals but no attachment.
            CONFIG.unlink(missing_ok=True)
            return
        raise ValueError('the expected personal disk is missing')
    result = subprocess.run(['blkid', '-p', '-s', 'UUID', '-o', 'value', str(disk)], capture_output=True, text=True)
    actual = result.stdout.strip()
    if actual != fsid:
        if mode != 'initialize' or result.returncode != 2 or actual:
            raise ValueError('personal disk UUID differs; refusing to mount or reformat it')
        signatures = json.loads(run('wipefs', '--json', '--no-act', disk))
        if signatures.get('signatures'): raise ValueError('new personal disk already has a filesystem; refusing to format')
        run('mkfs.ext4', '-q', '-m', '0', '-U', fsid, disk)
    if ROOT.is_symlink(): raise ValueError('personal mount point is a symlink')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not mounted(ROOT): run('mount', '-t', 'ext4', '-o', 'nosuid,nodev', disk, ROOT)
    actual_source = run('findmnt', '-n', '-o', 'UUID', '--target', ROOT)
    if actual_source != fsid: raise ValueError('another filesystem occupies the personal mount point')
    for name in config['folders']:
        source, target = ROOT / name, home / name
        if source.is_symlink(): raise ValueError('data folder is a symlink: ' + name)
        if not source.exists():
            source.mkdir(mode=0o700)
            os.chown(source, entry.pw_uid, entry.pw_gid)
        if not source.is_dir(): raise ValueError('invalid personal folder: ' + name)
        if not target.exists():
            target.mkdir(mode=0o700)
            os.chown(target, entry.pw_uid, entry.pw_gid)
        # First-disk migration is resumable. Existing data disks never merge a
        # different distro's local directories into the shared personal data.
        if mode in ('initialize', 'recover') and not (ROOT / '.uvm-initial-copy-complete').exists():
            run('cp', '-a', '--', str(target) + '/.', str(source))
        if not mounted(target): run('mount', '--bind', source, target)
    if mode in ('initialize', 'recover'): (ROOT / '.uvm-initial-copy-complete').touch(mode=0o600)
    run('sync')


def install(config):
    CONFIG.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(config)); CONFIG.chmod(0o600)
    PROGRAM.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    SERVICE.write_text('''[Unit]
Description=UbuntuVM personal data
After=local-fs.target systemd-udev-settle.service
Before=display-manager.service systemd-user-sessions.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /usr/local/lib/ubuntu-vm/personal-data.py boot
ExecStop=/usr/bin/python3 /usr/local/lib/ubuntu-vm/personal-data.py stop
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
''')
    # Mount failures must not log users into a misleading empty home.
    for name in ('display-manager.service', 'systemd-user-sessions.service'):
        path = Path('/etc/systemd/system') / (name + '.d')
        path.mkdir(parents=True, exist_ok=True)
        (path / 'ubuntu-vm-data.conf').write_text('[Unit]\nRequires=ubuntu-vm-personal-data.service\nAfter=ubuntu-vm-personal-data.service\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', 'ubuntu-vm-personal-data.service')


def main():
    if os.geteuid(): raise ValueError('personal data setup requires root')
    if sys.argv[1] in ('boot', 'stop'):
        if CONFIG.exists():
            config = json.loads(CONFIG.read_text())
            if sys.argv[1] == 'boot': mount(config)
            else: unmount(config)
        return
    config, mode = json.loads(sys.argv[1]), sys.argv[2]
    if mode == 'detach':
        if CONFIG.exists(): unmount(json.loads(CONFIG.read_text()))
        CONFIG.unlink(missing_ok=True)
        return
    # Install recovery information before migration; retries preserve originals.
    if CONFIG.exists(): unmount(json.loads(CONFIG.read_text()))
    install(config)
    mount(config, mode)
    print('Personal folders are ready. Original per-distro folders were preserved.')


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
