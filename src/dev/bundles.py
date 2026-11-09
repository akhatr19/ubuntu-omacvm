"""Stopped, content-addressed disk bundles. Never archive host SSH private keys."""
import json
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from manifest import digest, fingerprint, integer, load, write_json
from runtime import HOME, ROOT, RUNTIME_COMMIT, VMS, config, disk_busy, private_dir, run, runtime_identity, vm_folder
from supervisor import free_port

FILES = ('disk.img', 'efi-vars.fd')


def copy_disk(source, target):
    result = subprocess.run(['cp', '-c', str(source), str(target)], capture_output=True)
    if result.returncode != 0:
        target.unlink(missing_ok=True)
        zeros = bytes(1024 * 1024)
        with open(source, 'rb') as incoming, open(target, 'xb') as outgoing:
            while True:
                block = incoming.read(len(zeros))
                if not block:
                    break
                if block == zeros:
                    outgoing.seek(len(block), 1)
                else:
                    outgoing.write(block)
            outgoing.truncate()
    target.chmod(0o600)


def describe(bundle, expected=None):
    bundle = Path(bundle).resolve()
    descriptor = bundle / 'bundle.json'
    if descriptor.stat().st_size > 1024 * 1024:
        raise ValueError('bundle descriptor is too large')
    data = json.loads(descriptor.read_text())
    if not isinstance(data, dict) or data.get('schema') != 1 or data.get('kind') not in ('base', 'environment'):
        raise ValueError('unsupported bundle')
    if data.get('runtime_commit') != RUNTIME_COMMIT or set(data.get('files', {})) != set(FILES):
        raise ValueError('bundle runtime or files differ from this release')
    if data.get('runtime_sha256') != runtime_identity():
        raise ValueError('bundle needs the exact runtime shipped with its base build')
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', str(data.get('user', ''))):
        raise ValueError('invalid bundle user')
    integer(data.get('disk_gb'), 1, 65536, 'bundle disk_gb')
    if (bundle / 'disk.img').stat().st_size != data['disk_gb'] * (1024 ** 3):
        raise ValueError('bundle disk size differs from its descriptor')
    checksum = fingerprint(data)
    if expected and checksum != expected:
        raise ValueError('base bundle identity does not match the manifest')
    for name in FILES:
        file = bundle / name
        if file.is_symlink() or not file.is_file() or digest(file) != data['files'][name]:
            raise ValueError(f'bundle checksum mismatch: {name}')
    if data['kind'] == 'environment':
        with tempfile.TemporaryDirectory(prefix='uvm-definition-') as folder:
            restore_definition(Path(folder), data)
    return data, checksum


def export(vm, target, kind='environment'):
    target = Path(target).resolve()
    if target.exists():
        raise ValueError('export destination already exists')
    if disk_busy(vm):
        raise ValueError('shut the environment down before exporting or cloning it')
    metadata = config(vm)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.uvm-export-', dir=target.parent))
    try:
        for name in FILES:
            copy_disk(vm / name, temporary / name)
        data = {'schema': 1, 'kind': kind, 'runtime_commit': RUNTIME_COMMIT, 'runtime_sha256': runtime_identity(),
                'user': metadata['user'], 'disk_gb': (vm / 'disk.img').stat().st_size // (1024 ** 3),
                'files': {name: digest(temporary / name) for name in FILES}}
        if kind == 'environment':
            data['manifest'] = metadata['manifest']
            data['scripts'] = {name: base64.b64encode((vm / 'definition' / name).read_bytes()).decode()
                               for name in metadata['manifest']['provision']}
            lock = vm / 'uvm.lock.json'
            if lock.exists():
                data['lock'] = json.loads(lock.read_text())
        write_json(temporary / 'bundle.json', data)
        if (temporary / 'bundle.json').stat().st_size > 1024 * 1024:
            raise ValueError('bundle metadata and provisioning scripts exceed 1 MiB')
        temporary.rename(target)
        return fingerprint(data)
    except BaseException:
        shutil.rmtree(temporary)
        raise


def restore_definition(directory, data):
    scripts = data.get('scripts', {})
    if not isinstance(scripts, dict) or len(scripts) > 64:
        raise ValueError('invalid bundle provisioning scripts')
    write_json(directory / 'uvm.json', data['manifest'])
    for name, content in scripts.items():
        if not isinstance(name, str) or name in ('', '.', 'uvm.json') or Path(name).is_absolute() or '..' in Path(name).parts or '\\' in name:
            raise ValueError('invalid bundle script path')
        if not isinstance(content, str) or len(content) > 1024 * 1024:
            raise ValueError('invalid bundle script content')
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(base64.b64decode(content, validate=True))
    _, inputs, _ = load(directory / 'uvm.json')
    if set(scripts) != set(inputs['scripts']):
        raise ValueError('bundle scripts do not match the manifest')
    if data.get('lock'):
        from manifest import check_lock
        check_lock(data['lock'], inputs)


def create(bundle, settings, name, expected=None, imported=False):
    vm = vm_folder(name)
    if vm.exists():
        raise ValueError(f'environment already exists: {name}')
    data, checksum = describe(bundle, expected)
    cpus = int(subprocess.check_output(['sysctl', '-n', 'hw.ncpu']))
    memory = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'])) // (1024 ** 3)
    if settings['resources']['cpus'] > cpus or settings['resources']['memory_gb'] > memory:
        raise ValueError('manifest resources exceed this Mac; choose an explicit local override')
    private_dir(VMS)
    temporary = Path(tempfile.mkdtemp(prefix='.uvm-create-', dir=VMS))
    try:
        for file in FILES:
            copy_disk(Path(bundle) / file, temporary / file)
        reserved = {p['host'] for p in settings['ports']}
        for existing in VMS.glob('*/vm.env'):
            for line in existing.read_text().splitlines():
                if re.fullmatch(r'SSH_PORT=[0-9]+', line):
                    reserved.add(int(line.split('=')[1]))
        port = free_port()
        while port in reserved:
            port = free_port()
        vm_name = vm.name
        features = []
        for line in (ROOT / 'src/features.tsv').read_text().splitlines():
            if line and not line.startswith('#'):
                feature = line.split('\t')[0]
                features.append(feature + ('=on' if feature == 'gpu-compute' else '=off'))
        (temporary / 'features').write_text(' '.join(features) + '\n')
        (temporary / 'vm.env').write_text(
            f"NAME='{vm_name}'\nCPUS={settings['resources']['cpus']}\nMEM_MB={settings['resources']['memory_gb'] * 1024}\n"
            f"DISK_GB={data['disk_gb']}\nSSH_PORT={port}\nVM_USER='{data['user']}'\nKEYBOARD=us\n")
        for file, value in [('guest-os', 'ubuntu'), ('graphics', 'vulkan'), ('video-decode', 'av1'),
                            ('omacvm-version', (ROOT / 'src/VERSION').read_text().strip())]:
            (temporary / file).write_text(value + '\n')
        for file in ('ready', 'venus-ready', 'guest-pointer', 'ubuntu-installed'):
            (temporary / file).touch()
        private_dir(temporary / 'logs')
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'uvm-management', '-f', temporary / 'ssh-key'])
        write_json(temporary / 'uvm-env.json', {'schema': 1, 'name': name, 'vm_name': vm_name,
                   'user': data['user'], 'manifest': settings, 'ssh_port': port,
                   'base_sha256': settings['base']['sha256'], 'image_sha256': checksum, 'runtime_commit': RUNTIME_COMMIT,
                   'runtime_sha256': data['runtime_sha256']})
        if imported:
            restore_definition(private_dir(temporary / 'definition'), data)
        if imported and data.get('lock'):
            write_json(temporary / 'uvm.lock.json', data['lock'])
        temporary.rename(vm)
        return vm
    except BaseException:
        shutil.rmtree(temporary)
        raise


def build_base(iso, output):
    """Only a fresh installer-created VM can become a distributable base."""
    from runtime import app_bundle
    work = Path(tempfile.mkdtemp(prefix='base-', dir=private_dir(HOME / 'builds')))
    name = 'OmacVM Test-DeveloperBase' if os.environ.get('UVM_TEST_MODE') == '1' else 'DeveloperBase'
    env = os.environ.copy()
    env['OMACVM_VMS_ROOT'] = str(work)
    complete = False
    print('Building a fresh Ubuntu base with SSH-only login (no desktop password).', flush=True)
    try:
        run([ROOT / 'omacvm', 'ubuntu', 'build', '--iso', iso, '--vm-name', name, '--user', 'ubuntu',
             '--auth', 'ssh-only', '--profile', 'developer', '--ssh-port', str(free_port())], env=env)
        vm = work / name
        # Reuse the installer lifecycle while preparing its default headless boot.
        script = '''set -euo pipefail
source "$1/vm-common.sh"
vm_load "$2"
trap 'qemu_running && qemu_quit || true' EXIT
qemu_headless dev-base "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 -device virtio-serial-pci,id=vser0
wait_ssh 180
vssh 'systemctl set-default multi-user.target; systemctl disable --now apt-daily.timer apt-daily-upgrade.timer; systemctl poweroff' || true
qemu_wait_exit 90
'''
        app = app_bundle()
        scripts = ROOT / 'app/scripts' if (ROOT / 'app/scripts').is_dir() else app / 'Contents/Resources/scripts'
        run(['/bin/bash', '-c', script, 'uvm-base', scripts, vm])
        write_json(vm / 'uvm-env.json', {'user': 'ubuntu'})
        checksum = export(vm, output, kind='base')
        complete = True
        print('Base SHA-256: ' + checksum, flush=True)
        return checksum
    finally:
        if complete and not disk_busy(work / name):
            shutil.rmtree(work)
        else:
            print(f'Base build retained for diagnosis at {work}', flush=True)
