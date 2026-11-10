"""Project operations on managed environments or existing Ubuntu desktop VMs."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import subprocess
import time
import tempfile

import integrate
import network
import runtime as rt


def project_path(value):
    if not isinstance(value, str) or not value.startswith('/') or value == '/' or len(value) > 4096 or any(ord(c) < 32 for c in value) or '..' in value.split('/'):
        raise ValueError('choose an absolute Linux project folder, without .. or control characters')
    return value.rstrip('/')


class Session:
    def __init__(self, vm, project, qga=None):
        self.vm = Path(vm).resolve()
        self.project = project_path(project)
        if os.environ.get('UVM_TEST_MODE') == '1' and not self.vm.name.startswith('OmacVM Test-'):
            raise ValueError('test mode refuses a personal VM')
        self.qga = Path(qga) if qga else None
        self.managed = (self.vm / 'uvm-env.json').is_file()
        if (self.vm / 'guest-os').read_text().strip() != 'ubuntu':
            raise ValueError('select an Ubuntu VM')
        if self.managed:
            self.metadata = rt.config(self.vm)
        else:
            fields = {}
            for line in (self.vm / 'vm.env').read_text().splitlines():
                key, _, value = line.partition('=')
                if key in ('NAME', 'VM_USER', 'SSH_PORT'):
                    words = shlex.split(value)
                    if len(words) == 1:
                        fields[key] = words[0]
            user = fields.get('VM_USER', '')
            port = int(fields.get('SSH_PORT', 0))
            if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user) or not 1024 <= port <= 65535:
                raise ValueError('invalid Ubuntu SSH configuration')
            self.metadata = {'name': 'desktop-' + hashlib.sha256(str(self.vm).encode()).hexdigest()[:12],
                             'vm_name': fields.get('NAME', self.vm.name), 'user': user, 'ssh_port': port,
                             'manifest': {'ssh_agent': False}}

    def ssh(self, tty=False):
        if self.managed:
            return rt.ssh_args(self.vm, tty=tty)
        known = integrate.quote(self.vm / 'workspace-known_hosts')
        return ['ssh', '-F', '/dev/null', '-i', str(self.vm / 'ssh-key'), '-p', str(self.metadata['ssh_port']),
                '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + known,
                *(['-t'] if tty else []), self.metadata['user'] + '@127.0.0.1']

    def ensure(self):
        active = rt.live(self.vm) if self.managed else rt.disk_busy(self.vm)
        print('Connecting to Ubuntu…' if active else 'Starting Ubuntu and waiting for SSH…', flush=True)
        if self.managed:
            rt.ensure_up(self.vm)
        else:
            if (self.vm / 'fast-network').exists():
                raise ValueError('turn off Fast network in VM settings to use localhost project connections')
            if not self.qga:
                raise ValueError('the desktop VM guest-agent socket is required')
            if not rt.disk_busy(self.vm):
                rt.run(['open', '-n', '-a', rt.app_bundle(), '--args', '--start', '--vm', self.metadata['vm_name']])
            deadline = time.monotonic() + 240
            last = ''
            while time.monotonic() < deadline:
                try:
                    result = rt.socket_request(self.qga, 'guest-exec', {'path': '/bin/cat',
                        'arg': ['/etc/ssh/ssh_host_ed25519_key.pub'], 'capture-output': True}, qga=True)
                    for _ in range(30):
                        key = rt.socket_request(self.qga, 'guest-exec-status', {'pid': result['pid']}, qga=True)
                        if key.get('exited'):
                            break
                        time.sleep(.1)
                    public = base64.b64decode(key.get('out-data', ''), validate=True).decode().strip()
                    network.public_keys(public)
                    if not public.startswith('ssh-ed25519 '):
                        raise ValueError('Ubuntu did not provide its SSH host key')
                    known = self.vm / 'workspace-known_hosts'
                    record = f'[127.0.0.1]:{self.metadata["ssh_port"]} ' + ' '.join(public.split()[:2]) + '\n'
                    if known.exists() and known.read_text() != record:
                        raise ValueError('SSH host key changed; verify this VM before replacing workspace-known_hosts')
                    known.write_text(record); known.chmod(0o600)
                    connected = subprocess.run(self.ssh() + ['true'], capture_output=True, timeout=5)
                    if connected.returncode == 0:
                        break
                    last = connected.stderr.decode(errors='replace')[-1000:]
                except ValueError:
                    raise
                except (OSError, RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
                    last = str(error)
                time.sleep(1)
            else:
                raise TimeoutError('Ubuntu SSH did not become ready: ' + last)
        print('Ubuntu is ready.', flush=True)

    def run(self, argv, capture=False):
        # SSH transports a quoted argv; no user input is interpreted as shell code.
        command = self.ssh() + [shlex.join(argv)]
        if not capture:
            return subprocess.run(command, check=True)
        # Bound responses from the guest before loading them into host memory.
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as error:
            limit = 1024 * 1024
            result = subprocess.run(command, stdout=out, stderr=error, timeout=30,
                preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit)))
            out.seek(0); error.seek(0)
            stdout = out.read(limit + 1).decode(errors='replace')
            stderr = error.read(limit + 1).decode(errors='replace')
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command, stdout, stderr)
            return subprocess.CompletedProcess(command, result.returncode, stdout, stderr)

    def info(self):
        source = '''import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
print(json.dumps({'exists':p.is_dir(),'devcontainer':(p/'.devcontainer/devcontainer.json').is_file() or (p/'.devcontainer.json').is_file(),'manifest':(p/'uvm.json').is_file(),'lock':(p/'uvm.lock.json').is_file()}))'''
        info = json.loads(self.run(['python3', '-c', source, self.project], capture=True).stdout)
        if not isinstance(info, dict) or any(type(info.get(key)) is not bool for key in ('exists', 'devcontainer', 'manifest', 'lock')):
            raise ValueError('invalid project status from Ubuntu')
        return info

    def ensure_git(self):
        found = self.run(['python3', '-c', 'import shutil; print(bool(shutil.which("git")))'], capture=True).stdout.strip()
        if found == 'True':
            return
        if self.managed:
            raise ValueError('Git is missing from this environment; provision its base profile before cloning')
        print('Installing Git in Ubuntu (desktop VM only)…', flush=True)
        result = rt.socket_request(self.qga, 'guest-exec', {'path': '/bin/bash', 'arg': ['-c',
            'set -e; export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends git'], 'capture-output': True}, qga=True)
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            status = rt.socket_request(self.qga, 'guest-exec-status', {'pid': result['pid']}, qga=True)
            if status.get('exited'):
                if status.get('exitcode') != 0:
                    detail = base64.b64decode(status.get('err-data', '')).decode(errors='replace')[-2000:]
                    raise RuntimeError('Ubuntu could not install Git: ' + detail)
                return
            time.sleep(.5)
        raise TimeoutError('Git installation is still running in Ubuntu; wait before starting another package operation')

    def editor(self, container=False):
        info = self.info()
        if not info['exists']:
            raise ValueError('Linux project folder does not exist; clone or import it first')
        if container:
            if not info['devcontainer']:
                raise ValueError('this project has no .devcontainer/devcontainer.json or .devcontainer.json')
            self.run(['docker', 'info', '--format', '{{.ServerVersion}}'], capture=True)
        proxy = None
        if not self.managed:
            proxy = shlex.join([str(rt.ROOT / 'uvm'), 'workspace', '--vm', str(self.vm),
                               '--qga', str(self.qga), '--project', self.project, '_proxy'])
        alias, _ = integrate.ssh_config(self.vm, install=True, metadata=self.metadata, proxy=proxy)
        integrate.open_editor(alias, self.project)
        if container:
            print('In VS Code, choose “Dev Containers: Reopen in Container” when prompted. Remote - SSH and Dev Containers extensions are required.', flush=True)


def main(args):
    session = Session(args.vm, args.project, args.qga)
    action = args.action
    if action == 'clone' and (not args.source or len(args.source) > 4096 or any(ord(c) < 32 for c in args.source)
            or not (args.source.startswith('https://') or re.match(r'^[a-zA-Z0-9_-]+@[a-zA-Z0-9.-]+:', args.source))):
        raise ValueError('use an HTTPS or git@host:repository Git URL')
    if action == 'import' and (not args.source or not Path(args.source).is_dir()):
        raise ValueError('choose a Mac folder to import')
    if action == 'export' and (not args.source or Path(args.source).exists()):
        raise ValueError('choose a new .tar.gz file for the export')
    session.ensure()
    if action == '_proxy':
        # Keep protocol output clean: ensure() status is routed to stderr by the caller.
        os.execv('/usr/bin/nc', ['nc', '127.0.0.1', str(session.metadata['ssh_port'])])
    if action == 'info':
        print(json.dumps(session.info()))
    elif action == 'init':
        session.run(['mkdir', '-p', '--', session.project])
    elif action == 'clone':
        session.ensure_git()
        session.run(['mkdir', '-p', '--', str(Path(session.project).parent)])
        session.run(['git', 'clone', '--', args.source, session.project])
    elif action == 'import':
        source = Path(args.source or '').resolve()
        session.run(['mkdir', '-p', '--', session.project])
        producer = subprocess.Popen(['tar', '--no-xattrs', '--exclude=node_modules', '--exclude=.venv', '--exclude=.DS_Store', '-cf', '-', '-C', str(source), '.'], stdout=subprocess.PIPE, env={**os.environ, 'COPYFILE_DISABLE': '1'})
        try:
            consumer = subprocess.run(session.ssh() + [shlex.join(['tar', '--no-same-owner', '--skip-old-files', '-xf', '-', '-C', session.project])], stdin=producer.stdout)
        finally:
            producer.stdout.close()
        if producer.wait() or consumer.returncode:
            raise RuntimeError('import stopped; existing Linux files were kept, not overwritten')
    elif action == 'export':
        output = Path(args.source or '')
        created = False
        process = None
        try:
            limit = min(4 * 1024 ** 3, shutil.disk_usage(output.parent).free - 2 * 1024 ** 3)
            if limit <= 0:
                raise ValueError('export needs at least 2 GiB of free disk reserve')
            with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
                created = True
                process = subprocess.Popen(session.ssh() + [shlex.join(['tar', '-czf', '-', '-C', session.project, '.'])], stdout=subprocess.PIPE)
                total = 0
                while True:
                    chunk = process.stdout.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > limit:
                        raise ValueError('archive exceeds the export limit (up to 4 GiB, leaving 2 GiB free)')
                    stream.write(chunk)
                if process.wait():
                    raise RuntimeError('project archive transfer failed')
        except BaseException:
            if created:
                output.unlink(missing_ok=True)
            raise
        finally:
            if process:
                process.stdout.close()
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=10)
        print('Saved archive: ' + str(output))
    elif action == 'terminal':
        os.execvp('ssh', session.ssh(tty=True) + ['cd ' + shlex.quote(session.project) + ' && exec bash -l'])
    elif action in ('code', 'container'):
        session.editor(container=action == 'container')
    return 0
