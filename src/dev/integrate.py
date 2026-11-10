"""Managed SSH aliases and explicit editor/Docker integration; preserve user configuration."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import urllib.parse

from runtime import HOME, ROOT, app_bundle, config, ensure_up, private_dir, run


def quote(value):
    value = str(value)
    if any(ord(c) < 32 for c in value):
        raise ValueError('configuration paths cannot contain control characters')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def ssh_config(vm, install=False, metadata=None, proxy=None):
    metadata = metadata or config(vm)
    name = metadata['name']
    alias = 'uvm-' + name
    folder = private_dir(HOME / 'ssh')
    file = folder / (name + '.conf')
    test = '1' if vm.name.startswith('OmacVM Test-Dev-') else '0'
    proxy = proxy or shlex.join(['env', f'UVM_HOME={HOME}', f'UVM_VMS_ROOT={vm.parent}',
                        f'UVM_APP={app_bundle()}', f'UVM_TEST_MODE={test}',
                        str(ROOT / 'uvm'), '--env', name, '_proxy'])
    file.write_text(f'''Host {alias}
  HostName 127.0.0.1
  Port {metadata['ssh_port']}
  User {metadata['user']}
  IdentityFile {quote(vm / 'ssh-key')}
  IdentitiesOnly yes
  UserKnownHostsFile {quote(vm / 'known_hosts')}
  StrictHostKeyChecking yes
  ForwardAgent {'yes' if metadata['manifest']['ssh_agent'] else 'no'}
  ProxyCommand {proxy.replace('%', '%%')}
''')
    file.chmod(0o600)
    if install:
        target = Path(os.environ.get('UVM_SSH_CONFIG', Path.home() / '.ssh/config'))
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        include = 'Include ' + quote(folder / '*.conf')
        old = target.read_text() if target.exists() else ''
        if include not in old.splitlines():
            if f'Host {alias}' in old.splitlines():
                raise ValueError('an SSH alias with this name already exists in your config')
            if target.is_symlink():
                raise ValueError('SSH config is a symlink; add the printed Include manually')
            fd, temporary = tempfile.mkstemp(prefix='.uvm-ssh-', dir=target.parent)
            try:
                with os.fdopen(fd, 'w') as stream:
                    stream.write(include + '\n' + old)
                if target.exists():
                    os.chmod(temporary, target.stat().st_mode & 0o777)
                os.replace(temporary, target)
            finally:
                Path(temporary).unlink(missing_ok=True)
    return alias, file


def editor(vm):
    ensure_up(vm)
    alias, _ = ssh_config(vm, install=True)
    metadata = config(vm)
    path = f'/home/{metadata["user"]}/Projects/{metadata["manifest"]["name"]}'
    open_editor(alias, path)


def open_editor(alias, path):
    executable = shutil.which('code')
    if not executable:
        candidates = [Path('/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'),
                      Path.home() / 'Applications/Visual Studio Code.app/Contents/Resources/app/bin/code']
        executable = next((str(p) for p in candidates if p.exists()), None)
    if not executable:
        raise ValueError('install VS Code and its Remote - SSH extension first')
    uri = 'vscode-remote://ssh-remote+' + alias + urllib.parse.quote(path)
    run([executable, '--folder-uri', uri])


def docker_context(vm, use=False):
    ensure_up(vm)
    alias, _ = ssh_config(vm, install=True)
    if not shutil.which('docker'):
        raise ValueError('Mac Docker CLI is not installed; uvm docker works without it')
    name = 'uvm-' + config(vm)['name']
    endpoint = 'ssh://' + alias
    result = subprocess.run(['docker', 'context', 'inspect', name], capture_output=True, text=True)
    if result.returncode == 0:
        if json.loads(result.stdout)[0]['Endpoints']['docker']['Host'] != endpoint:
            raise ValueError('Docker context name already belongs to another endpoint')
    else:
        run(['docker', 'context', 'create', name, '--docker', 'host=' + endpoint])
    if use:
        run(['docker', 'context', 'use', name])
    return name
