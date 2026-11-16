#!/usr/bin/env python3
"""Mount Mac-owned personal folders before the desktop; preserve local originals."""
import base64
import ctypes
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import sys
import uuid

STATE = Path('/var/lib/ubuntu-vm/home-folders.json')
BACKUP = 'UbuntuVM Local Folders'
P = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
libc = ctypes.CDLL(None, use_errno=True)


def selections(oem):
    result = {}
    for value in re.findall(rb'uvm.home=([^\0]*)', oem):
        index, encoded = value.split(b':', 1)
        name = base64.b64decode(encoded, validate=True).decode()
        if not index.isdigit() or not 0 <= int(index) < 16 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 _-]{0,63}', name):
            raise ValueError('invalid home folder grant')
        if name.lower() in (BACKUP.lower(), 'mac', 'shared'): raise ValueError('reserved home folder name')
        if name.lower() in {n.lower() for n in result} or int(index) in result.values():
            raise ValueError('duplicate home folder grant')
        result[name] = int(index)
    return result


def save(value):
    temporary = STATE.with_suffix('.new')
    with open(temporary, 'w') as stream:
        json.dump(value, stream)
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, STATE)
    fd = os.open(STATE.parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def directory(parent, name, user):
    created = False
    try:
        os.mkdir(name, 0o755, dir_fd=parent); created = True
    except FileExistsError: pass
    fd = os.open(name, P, dir_fd=parent)
    info = os.fstat(fd)
    if not created and info.st_uid != user.pw_uid:
        os.close(fd); raise ValueError('home folder has another owner: ' + name)
    if created:
        # fchown on O_PATH is unavailable; reopen this exact directory via its fd.
        writable = os.open(f'/proc/self/fd/{fd}', os.O_RDONLY | os.O_DIRECTORY)
        os.fchown(writable, user.pw_uid, user.pw_gid); os.close(writable)
    return fd


def source(path):
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        mount = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4])
        if mount == path:
            tail = fields[fields.index('-') + 1:]
            return tail[1] if tail[0] == '9p' else 'other'
    return None


def mount(fd, tag):
    target = f'/proc/self/fd/{fd}'.encode()
    # No read/writeback cache: other VMs and the Mac can change these files.
    options = b'trans=virtio,version=9p2000.L,access=client,msize=512000,cache=none'
    if libc.mount(tag.encode(), target, b'9p', 2 | 4, options) != 0:  # nosuid,nodev
        raise OSError(ctypes.get_errno(), 'cannot mount ' + tag)


def main():
    if os.geteuid() != 0: raise ValueError('home folder setup requires root')
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(STATE.with_suffix('.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        user = pwd.getpwuid(1000)
        home = os.open(user.pw_dir, P)
        try:
            table = Path('/sys/firmware/dmi/tables/DMI')
            selected = selections(table.read_bytes() if table.exists() else b'')
            state = json.loads(STATE.read_text()) if STATE.exists() else {'backups': {}, 'folders': []}
            backups = state['backups']
            stopping = sys.argv[1:] == ['--stop']
            for name in set(state['folders']) | set(selected) | set(backups):
                if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 _-]{0,63}', name): raise ValueError('invalid saved folder name')
                if name in backups:
                    try:
                        backup = os.open(BACKUP, P, dir_fd=home)
                        try: os.stat(backups[name], dir_fd=backup, follow_symlinks=False)
                        finally: os.close(backup)
                    except FileNotFoundError:
                        del backups[name]; save(state)  # Deleted backup, or interrupted before the move.
                path = str(Path(user.pw_dir) / name)
                existing = source(path)
                tag = f'uvm-home-{selected[name]}' if name in selected else None
                if existing and not existing.startswith('uvm-home-') and tag is None:
                    continue  # A legacy personal disk owns this folder; don't cover it.
                if existing and (stopping or existing != tag):
                    if not existing.startswith('uvm-home-'): raise ValueError('another filesystem occupies ' + name)
                    # An unprivileged user cannot rename a mounted directory.
                    # Holding its fd ourselves would keep an otherwise idle mount busy.
                    if libc.umount2(path.encode(), 0) != 0:
                        raise OSError(ctypes.get_errno(), 'close applications using ' + name)
                    existing = None
                if stopping: continue
                if tag is None:
                    if name in backups:
                        backup = os.open(BACKUP, P, dir_fd=home)
                        try:
                            # rmdir refuses to replace a nonempty directory or a link.
                            try: os.rmdir(name, dir_fd=home)
                            except FileNotFoundError: pass
                            os.rename(backups[name], name, src_dir_fd=backup, dst_dir_fd=home)
                        finally: os.close(backup)
                        del backups[name]; save(state)
                    continue
                if existing == tag: continue
                fd = directory(home, name, user)
                try:
                    if os.listdir(f'/proc/self/fd/{fd}'):
                        if name in backups: raise ValueError('local backup already exists for ' + name)
                        backup = directory(home, BACKUP, user)
                        try:
                            # Never merge or overwrite the existing files automatically.
                            key = name + '-' + uuid.uuid4().hex[:12]
                            backups[name] = key; save(state)
                            os.rename(name, key, src_dir_fd=home, dst_dir_fd=backup)
                        finally: os.close(backup)
                        os.close(fd); fd = directory(home, name, user)
                    if name not in state['folders']:
                        state['folders'].append(name); save(state)
                    mount(fd, tag)
                finally: os.close(fd)
            if not stopping:
                state['folders'] = list(selected); save(state)
        finally: os.close(home)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError) as error:
        print('UbuntuVM home folders: ' + str(error), file=sys.stderr)
        sys.exit(1)
