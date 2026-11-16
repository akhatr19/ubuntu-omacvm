#!/usr/bin/env python3
"""Live NFS mounts supplied through the Mac's authenticated SSH connection."""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time

ROOT = Path('/etc/ubuntu-vm/shared-folders')
STOPPING = Path('/run/ubuntu-vm-shared-stopping')


def run(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode: raise RuntimeError(result.stderr[-2000:] or result.stdout[-2000:] or 'command failed: ' + str(args[0]))
    return result.stdout.strip()


def validate(config):
    if not re.fullmatch(r'[0-9a-f]{32}', config['id']): raise ValueError('invalid shared folder ID')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', config['user']): raise ValueError('invalid account')
    user = pwd.getpwnam(config['user'])
    if user.pw_uid != 1000 or user.pw_gid != 1000: raise ValueError('shared folders require account UID/GID 1000')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 _.-]{0,60}', config['folder']) or '..' in config['folder']:
        raise ValueError('invalid folder name')
    if 'client_id' in config and not re.fullmatch(r'[0-9a-f]{64}', str(config['client_id'])): raise ValueError('invalid client identity')
    if type(config['port']) is not int or not 1024 <= config['port'] <= 65535: raise ValueError('invalid connection port')
    home = Path(user.pw_dir)
    parent = home / 'Shared'
    target = parent / config['folder']
    for path in (home, parent, target):
        if path.is_symlink() or (path.exists() and not path.is_dir()): raise ValueError('shared mount path is not a local directory')
    return user, parent, target


def ready(config):
    _, _, path = validate(config)
    if not os.path.ismount(path): return False
    marker = path / '.ubuntu-vm-share-id'
    return marker.is_file() and marker.stat().st_size <= 128 and marker.read_text().strip() == config['id']


def install():
    if not Path('/sbin/mount.nfs').exists() and not Path('/usr/sbin/mount.nfs').exists():
        run('apt-get', 'update')
        run('apt-get', 'install', '-y', '--no-install-recommends', 'nfs-common')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    service = Path('/etc/systemd/system/ubuntu-vm-shared-folders.service')
    service.write_text('''[Unit]
Description=Wait for UbuntuVM shared folders
After=network.target ssh.service systemd-logind.service
Before=display-manager.service user@1000.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /usr/local/lib/ubuntu-vm/shared-files-client.py wait
ExecStop=/usr/bin/python3 /usr/local/lib/ubuntu-vm/shared-files-client.py stop
TimeoutStartSec=180
TimeoutStopSec=30
[Install]
WantedBy=multi-user.target
''')
    Path('/etc/systemd/system/systemd-user-sessions.service.d/ubuntu-vm-shared.conf').unlink(missing_ok=True)
    for name in ('display-manager.service',):
        folder = Path('/etc/systemd/system') / (name + '.d')
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'ubuntu-vm-shared.conf').write_text('[Unit]\nRequires=ubuntu-vm-shared-folders.service\nAfter=ubuntu-vm-shared-folders.service\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', 'ubuntu-vm-shared-folders.service')


def configure_identity(config):
    # Separate cloned clients even when their hostnames and loopback IPs match.
    run('modprobe', 'nfsv4')
    identifier = Path('/sys/fs/nfs/net/nfs_client/identifier')
    if config.get('client_id'):
        if not identifier.exists(): raise ValueError('kernel does not expose NFS client identity configuration')
        if identifier.read_text().strip() in ('', '(null)'):
            identifier.write_text(config['client_id'] + '\n')


def mount(config):
    if STOPPING.exists(): raise ValueError('VM is shutting down; shared folders will reconnect at the next start')
    user, parent, target = validate(config)
    for path in (parent, target):
        if not path.exists():
            path.mkdir(mode=0o700)
            os.chown(path, user.pw_uid, user.pw_gid)
    if not os.path.ismount(target):
        os.chown(target, 0, 0); target.chmod(0o555)
    if os.path.ismount(target):
        if not ready(config): raise ValueError('a different filesystem occupies the shared folder')
        return
    if any(target.iterdir()): raise ValueError('shared mount point contains local files; move them before connecting')
    configure_identity(config)
    options = f'vers=4.1,proto=tcp,port={config["port"]},hard,timeo=50,retrans=2,retry=0,actimeo=0,lookupcache=none,nosuid,nodev'
    run('mount', '-t', 'nfs', '-o', options, '127.0.0.1:/', target)
    if not ready(config):
        run('umount', target)
        raise ValueError('shared folder identity did not match')


def main():
    if os.geteuid(): raise ValueError('shared folder setup requires root')
    if sys.argv[1] == 'stop':
        STOPPING.touch(mode=0o600)
        state = subprocess.run(['systemctl', 'is-system-running'], capture_output=True, text=True).stdout.strip()
        if state == 'stopping':
            # End regular user sessions before flushing their files. Root's
            # private SSH transport remains alive until after this service.
            subprocess.run(['loginctl', 'terminate-user', '1000'], capture_output=True)
        if ROOT.exists():
            for file in ROOT.glob('*.json'):
                _, _, target = validate(json.loads(file.read_text()))
                for attempt in range(10):
                    if not os.path.ismount(target): break
                    try:
                        run('umount', target); break
                    except RuntimeError:
                        if attempt == 9: raise
                        time.sleep(.3)
        return
    if sys.argv[1] == 'wait':
        STOPPING.unlink(missing_ok=True)
        table = Path('/sys/firmware/dmi/tables/DMI')
        oem = table.read_bytes() if table.exists() else b''
        expected = [file for file in ROOT.glob('*.json') if (b'uvm.shared=' + file.stem.encode()) in oem] if ROOT.exists() else []
        end = time.monotonic() + 150
        while time.monotonic() < end:
            if all(ready(json.loads(file.read_text())) for file in expected): return
            time.sleep(.5)
        raise ValueError('shared folders are unavailable; check the file service in Workbench')
    action, config = sys.argv[1], json.loads(sys.argv[2])
    _, _, target = validate(config)
    file = ROOT / (config['id'] + '.json')
    if action == 'remove':
        if os.path.ismount(target): run('umount', target)
        file.unlink(missing_ok=True)
        return
    if action in ('register', 'register-only'):
        install()
        file.write_text(json.dumps(config)); file.chmod(0o600)
    if action != 'register-only':
        mount(config)
        run('systemctl', 'start', '--no-block', 'ubuntu-vm-shared-folders.service')
    print(str(target))


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
