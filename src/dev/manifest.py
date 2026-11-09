"""Versioned developer manifests and content locks; no host-specific paths in locks."""
import hashlib
import datetime
import json
import re
from pathlib import Path

SCHEMA = 1
PROFILES = {
    'base': ['build-essential', 'git', 'curl', 'ca-certificates', 'pkg-config'],
    'python': ['python3', 'python3-venv', 'python3-pip'],
    'node': ['nodejs', 'npm'],
    'rust': ['rustc', 'cargo'],
    'docker': ['docker.io', 'docker-compose-v2'],
}


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read_script(path, expected):
    with open(path, 'rb') as stream:
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f'provisioning script changed during setup: {path}')
    return data


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.new')
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{label} must be an integer from {low} to {high}')
    return value


def load(path):
    path = Path(path).resolve()
    data = json.loads(path.read_text())
    allowed = {'schema', 'name', 'base', 'resources', 'snapshot', 'profiles', 'packages',
               'provision', 'ports', 'auto_ports', 'idle_minutes', 'ssh_agent', 'interop', 'git', 'images', 'desktop_autologin'}
    if not isinstance(data, dict) or set(data) - allowed or data.get('schema') != SCHEMA:
        raise ValueError('unsupported manifest schema or fields')
    if not isinstance(data.get('name'), str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,39}', data['name']):
        raise ValueError('name must be a lowercase environment slug (40 characters maximum)')
    base = data.get('base', {})
    if not isinstance(base, dict) or set(base) != {'path', 'sha256'} or not isinstance(base['path'], str):
        raise ValueError('base needs path and sha256')
    if not re.fullmatch(r'[0-9a-f]{64}', str(base['sha256'])):
        raise ValueError('base.sha256 must pin an immutable base bundle')
    resource = data.setdefault('resources', {'cpus': 4, 'memory_gb': 8})
    if not isinstance(resource, dict) or set(resource) != {'cpus', 'memory_gb'}:
        raise ValueError('resources supports cpus and memory_gb')
    integer(resource['cpus'], 1, 256, 'cpus')
    integer(resource['memory_gb'], 2, 1024, 'memory_gb')
    if not re.fullmatch(r'20[0-9]{6}T[0-9]{6}Z', str(data.get('snapshot', ''))):
        raise ValueError('snapshot must be a fixed Ubuntu snapshot timestamp, YYYYMMDDTHHMMSSZ')
    datetime.datetime.strptime(data['snapshot'], '%Y%m%dT%H%M%SZ')
    packages = []
    profiles = data.setdefault('profiles', ['base'])
    if not isinstance(profiles, list) or any(not isinstance(p, str) or p not in PROFILES for p in profiles):
        raise ValueError('unknown toolchain profile')
    for profile in profiles:
        packages.extend(PROFILES[profile])
    requested = data.setdefault('packages', [])
    if not isinstance(requested, list):
        raise ValueError('packages must be a list')
    packages.extend(requested)
    if any(not isinstance(p, str) or not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*(?::arm64)?(?:=[A-Za-z0-9.+:~_-]+)?', p) for p in packages):
        raise ValueError('invalid apt package specification')
    scripts = data.setdefault('provision', [])
    if not isinstance(scripts, list) or len(scripts) > 64:
        raise ValueError('provision must list at most 64 project-relative scripts')
    hashes = {}
    for script in scripts:
        if not isinstance(script, str):
            raise ValueError('provision entries must be paths')
        file = (path.parent / script).resolve()
        if script == 'uvm.json' or Path(script).is_absolute() or path.parent not in file.parents or not file.is_file():
            raise ValueError('provision scripts must stay inside the project')
        if file.stat().st_size > 1024 * 1024:
            raise ValueError('provision scripts must be smaller than 1 MiB')
        hashes[script] = digest(file)
    source = data.get('git')
    if source is not None:
        if not isinstance(source, dict) or set(source) != {'url', 'commit'}:
            raise ValueError('git needs url and a full commit')
        if not isinstance(source['url'], str) or not source['url'] or '\0' in source['url']:
            raise ValueError('invalid git URL')
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', str(source['commit'])):
            raise ValueError('git.commit must be a full immutable commit')
    images = data.setdefault('images', [])
    if not isinstance(images, list) or len(images) > 64 or any(
            not isinstance(image, str) or not re.fullmatch(r'[A-Za-z0-9./:_-]+@sha256:[0-9a-f]{64}', image) for image in images):
        raise ValueError('container images must be pinned with @sha256:...')
    if images and 'docker' not in profiles:
        raise ValueError('container images require the docker profile')
    ports = data.setdefault('ports', [])
    if not isinstance(ports, list) or len(ports) > 64:
        raise ValueError('ports must contain at most 64 mappings')
    hosts = set()
    for port in ports:
        if not isinstance(port, dict) or set(port) != {'host', 'guest'}:
            raise ValueError('ports use {"host": 3000, "guest": 3000}')
        integer(port['host'], 1024, 65535, 'host port')
        integer(port['guest'], 1, 65535, 'guest port')
        if port['host'] in hosts:
            raise ValueError('duplicate host port')
        hosts.add(port['host'])
    for field, default in [('auto_ports', True), ('ssh_agent', False), ('desktop_autologin', True)]:
        if type(data.setdefault(field, default)) is not bool:
            raise ValueError(f'{field} must be boolean')
    if data.setdefault('idle_minutes', None) is not None:
        integer(data['idle_minutes'], 1, 1440, 'idle_minutes')
    interop = data.setdefault('interop', [])
    if not isinstance(interop, list) or any(not isinstance(p, str) or p not in ('browser', 'clipboard', 'export') for p in interop):
        raise ValueError('interop supports browser, clipboard and export')
    semantic = {**data, 'base': {'sha256': base['sha256']}}
    implementation = Path(__file__).parent
    tools = [implementation / 'manifest.py', implementation / 'provision.py', *sorted((implementation / 'guest').glob('*'))]
    return data, {'schema': SCHEMA, 'manifest_sha256': fingerprint(semantic),
                  'packages': sorted(set(packages)),
                  'base_sha256': base['sha256'], 'scripts': hashes,
                  'provisioner_sha256': fingerprint({str(p.relative_to(implementation)): digest(p) for p in tools if p.is_file()})}, sorted(set(packages))


def check_lock(expected, actual):
    if not isinstance(expected, dict):
        raise ValueError('lock must be an object')
    for key in ('schema', 'manifest_sha256', 'base_sha256', 'scripts', 'packages', 'provisioner_sha256'):
        if expected.get(key) != actual.get(key):
            raise ValueError(f'lock mismatch: {key}; explicitly run uvm lock to update it')
    for field in ('apt_requested', 'apt_inventory'):
        values = expected.get(field)
        if not isinstance(values, list) or any(not isinstance(p, str) or not re.fullmatch(
                r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?=[A-Za-z0-9.+:~_-]+', p) for p in values):
            raise ValueError(f'invalid locked {field}')
