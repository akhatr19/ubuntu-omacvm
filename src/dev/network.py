"""Local network overrides shared by the Ubuntu GUI and developer supervisor."""
import base64
import json
from pathlib import Path
import re
import struct
import subprocess
import sys


def public_keys(text):
    if not isinstance(text, str) or len(text.encode()) > 16384:
        raise ValueError('public keys must fit in 16 KiB')
    keys = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    if len(keys) > 32:
        raise ValueError('at most 32 public keys are supported')
    for key in keys:
        fields = key.split()
        if len(fields) < 2 or fields[0] not in ('ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256'):
            raise ValueError('paste public keys, without authorized_keys options or private keys')
        data = base64.b64decode(fields[1], validate=True)
        if len(data) < 16:
            raise ValueError('invalid public key')
        length = struct.unpack('>I', data[:4])[0]
        if data[4:4 + length] != fields[0].encode():
            raise ValueError('public key type does not match its data')
    return keys


def load(vm, defaults=None):
    defaults = defaults or {}
    data = {'schema': 1, 'ssh_lan': False, 'ssh_port': 2222, 'ports': [{**p, 'lan': False} for p in defaults.get('ports', [])],
            'auto_ports': defaults.get('auto_ports', False), 'idle_minutes': defaults.get('idle_minutes'), 'public_keys': ''}
    path = Path(vm) / 'developer-network.json'
    if path.exists():
        if path.stat().st_size > 32768:
            raise ValueError('network settings are too large')
        override = json.loads(path.read_text())
        if not isinstance(override, dict) or set(override) - set(data):
            raise ValueError('unsupported network settings')
        data.update(override)
    if type(data['schema']) is not int or data['schema'] != 1:
        raise ValueError('unsupported network settings version')
    for field in ('ssh_lan', 'auto_ports'):
        if type(data[field]) is not bool:
            raise ValueError(field + ' must be boolean')
    if data['idle_minutes'] is not None and (type(data['idle_minutes']) is not int or not 1 <= data['idle_minutes'] <= 1440):
        raise ValueError('idle timeout must be 1–1440 minutes or null')
    if not isinstance(data['ports'], list) or len(data['ports']) > 64:
        raise ValueError('at most 64 port forwards are supported')
    if type(data['ssh_port']) is not int or not 1024 <= data['ssh_port'] <= 65535:
        raise ValueError('LAN SSH port must be 1024–65535')
    hosts = {data['ssh_port']} if data['ssh_lan'] else set()
    for port in data['ports']:
        if not isinstance(port, dict) or set(port) != {'host', 'guest', 'lan'} or type(port['lan']) is not bool:
            raise ValueError('invalid port forward')
        if type(port['host']) is not int or not 1024 <= port['host'] <= 65535 or type(port['guest']) is not int or not 1 <= port['guest'] <= 65535:
            raise ValueError('invalid port number')
        if port['guest'] == 22:
            raise ValueError('configure port 22 in the SSH section')
        if port['host'] in hosts:
            raise ValueError('duplicate host port')
        hosts.add(port['host'])
    public_keys(data['public_keys'])
    return data


def apply_keys(user, encoded):
    """Runs only inside Ubuntu through its private guest-agent connection."""
    import os
    if sys.platform != 'linux' or 'ID=ubuntu' not in Path('/etc/os-release').read_text().splitlines():
        raise ValueError('SSH key configuration runs only inside an Ubuntu guest')
    if os.geteuid() != 0 or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', user) or user == 'root':
        raise ValueError('a non-root Ubuntu account is required')
    keys = public_keys(base64.b64decode(encoded, validate=True).decode())
    directory = Path('/etc/ssh/ubuntu-vm')
    directory.mkdir(mode=0o755, exist_ok=True)
    target = directory / user
    temporary = target.with_suffix('.new')
    temporary.write_text(''.join(key + '\n' for key in keys))
    temporary.chmod(0o644)
    temporary.replace(target)
    Path('/etc/ssh/sshd_config.d/00-ubuntu-vm.conf').write_text(
        'AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/ubuntu-vm/%u\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n')
    Path('/run/sshd').mkdir(mode=0o755, exist_ok=True)
    subprocess.run(['/usr/sbin/sshd', '-t'], check=True)
    subprocess.run(['systemctl', 'try-reload-or-restart', 'ssh'], check=True)


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != '--guest':
        sys.exit('internal SSH key configuration helper')
    apply_keys(sys.argv[2], sys.argv[3])
