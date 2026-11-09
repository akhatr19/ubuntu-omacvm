#!/usr/bin/env python3
"""UbuntuVM developer environments: Linux tools, reproducible inputs, optional desktop."""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys

import bundles
import integrate
from manifest import SCHEMA, check_lock, load, read_script, write_json
from provision import apply, verify
import runtime as rt


def parser():
    p = argparse.ArgumentParser(prog='uvm', description=__doc__)
    p.add_argument('-e', '--env', help='managed environment name')
    p.add_argument('-f', '--manifest', type=Path, help='project uvm.json (otherwise search parent folders)')
    sub = p.add_subparsers(dest='command')
    init = sub.add_parser('init', help='write a versioned project manifest')
    init.add_argument('--base', required=True, type=Path)
    init.add_argument('--name', default='dev')
    init.add_argument('--snapshot', default=(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).strftime('%Y%m%dT000000Z'))
    init.add_argument('--profile', action='append', default=['base'])
    init.add_argument('--output', type=Path, default=Path('uvm.json'))
    base = sub.add_parser('base', help='build or verify an immutable Ubuntu base bundle').add_subparsers(dest='base_action', required=True)
    build = base.add_parser('build')
    build.add_argument('--iso', type=Path, required=True)
    build.add_argument('--output', type=Path, required=True)
    show = base.add_parser('inspect')
    show.add_argument('bundle', type=Path)
    create = sub.add_parser('create', help='clone a pinned base and provision the environment')
    create.add_argument('--name', help='local instance name; project inputs remain unchanged')
    create.add_argument('--locked', action='store_true')
    sub.add_parser('lock', help='resolve a new lock in a fresh disposable environment')
    for command in ('up', 'code', 'ports', 'verify', 'provision', 'desktop'):
        sub.add_parser(command)
    sub.add_parser('shell').add_argument('--root', action='store_true')
    execute = sub.add_parser('run', help='run argv in Linux, preserving stdin and exit status')
    execute.add_argument('--cwd')
    execute.add_argument('--agent', action='store_true')
    execute.add_argument('--root', action='store_true')
    execute.add_argument('argv', nargs=argparse.REMAINDER)
    docker = sub.add_parser('docker', help='use the guest Docker CLI without Docker Desktop')
    docker.add_argument('argv', nargs=argparse.REMAINDER)
    context = sub.add_parser('docker-context')
    context.add_argument('--use', action='store_true', help='also switch the Mac Docker context')
    sync = sub.add_parser('sync', help='copy Mac project files into Linux without deleting guest files')
    sync.add_argument('source', nargs='?', type=Path)
    stop = sub.add_parser('stop')
    stop.add_argument('--force', action='store_true')
    for command in ('list', 'status'):
        sub.add_parser(command).add_argument('--json', action='store_true')
    export = sub.add_parser('export', help='export a stopped disk bundle, excluding host private keys')
    export.add_argument('output', type=Path)
    imported = sub.add_parser('import')
    imported.add_argument('bundle', type=Path)
    imported.add_argument('--name', required=True)
    clone = sub.add_parser('clone', help='clone a stopped environment with fresh management credentials')
    clone.add_argument('--name', required=True)
    ssh = sub.add_parser('ssh-config')
    ssh.add_argument('--install', action='store_true', help='add a managed Include to your SSH config')
    return p


def manifest_path(argument):
    if argument:
        return argument.resolve()
    for folder in [Path.cwd(), *Path.cwd().parents]:
        file = folder / 'uvm.json'
        if file.exists():
            return file
    return None


def environments():
    if not rt.VMS.is_dir():
        return []
    prefix = 'OmacVM Test-Dev-' if os.environ.get('UVM_TEST_MODE') == '1' else 'Dev-'
    result = []
    for vm in sorted(rt.VMS.iterdir()):
        if vm.is_dir() and vm.name.startswith(prefix) and (vm / 'uvm-env.json').is_file():
            metadata = rt.config(vm)
            state = rt.live(vm)
            result.append({'name': metadata['name'], 'status': 'running' if state else 'stopped',
                           'mode': state.get('mode') if state else None, 'resources': rt.local_resources(vm),
                           'folder': str(vm)})
    return result


def selected(args, path):
    if args.env:
        vm = rt.vm_folder(args.env)
    elif path:
        settings, _, _ = load(path)
        vm = rt.vm_folder(settings['name'])
    else:
        found = environments()
        if len(found) != 1:
            raise ValueError('use --env NAME or run inside a project with uvm.json')
        vm = Path(found[0]['folder'])
    rt.config(vm)
    return vm


def create(path, name=None, require_lock=False, update=False):
    settings, inputs, packages = load(path)
    lock_path = path.with_name('uvm.lock.json')
    locked = json.loads(lock_path.read_text()) if lock_path.exists() and not update else None
    if require_lock and not locked:
        raise ValueError('a committed uvm.lock.json is required; run uvm lock first')
    if locked:
        check_lock(locked, inputs)
    base = (path.parent / settings['base']['path']).resolve()
    vm = bundles.create(base, settings, name or settings['name'], settings['base']['sha256'])
    try:
        definition = rt.private_dir(vm / 'definition')
        write_json(definition / 'uvm.json', settings)
        for script in settings['provision']:
            target = definition / script
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(read_script(path.parent / script, inputs['scripts'][script]))
        metadata = rt.config(vm)
        metadata['project_root'] = str(path.parent)
        write_json(vm / 'uvm-env.json', metadata)
        print('Starting ' + metadata['name'], flush=True)
        rt.ensure_up(vm)
        locked = apply(vm, path, inputs, packages, locked)
        write_json(lock_path, locked)
        return vm
    except BaseException:
        print(f'Environment retained for diagnosis at {vm}', file=sys.stderr)
        raise


def execute(vm, argv, cwd=None, agent=False, root=False):
    rt.ensure_up(vm)
    metadata = rt.config(vm)
    project = f'/home/{metadata["user"]}/Projects/{metadata["manifest"]["name"]}'
    if cwd is None:
        cwd = project
        root = metadata.get('project_root')
        if root:
            try:
                relative = Path.cwd().relative_to(root)
                cwd = str(Path(project) / relative)
            except ValueError:
                pass
    identity = secrets.token_hex(16)
    request = base64.b64encode(json.dumps({'id': identity, 'argv': argv, 'cwd': cwd}).encode()).decode()
    leases = rt.private_dir(rt.sockets(vm) / 'leases')
    lease = leases / str(os.getpid())
    lease.touch()
    try:
        command = rt.ssh_args(vm, tty=sys.stdin.isatty() and sys.stdout.isatty(),
                              agent=agent or metadata['manifest']['ssh_agent'], root=root)
        process = subprocess.Popen(command + ['uvm-exec ' + request])
        try:
            status = process.wait()
            return status if status >= 0 else 128 - status
        except KeyboardInterrupt:
            subprocess.run(rt.ssh_args(vm, root=root) + ['uvm-exec --cancel ' + identity], timeout=10)
            process.wait(timeout=10)
            return 130
    finally:
        lease.unlink(missing_ok=True)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['_supervise']:
        from supervisor import supervise
        supervise(Path(argv[1]).resolve(), desktop=argv[2:] == ['--desktop'])
        return 0
    if len(argv) == 3 and argv[0] == '--env' and argv[2] == '_proxy':
        vm = rt.vm_folder(argv[1])
        state = rt.ensure_up(vm)
        os.execv('/usr/bin/nc', ['nc', '127.0.0.1', str(state['ssh_port'])])
    args = parser().parse_args(argv)
    if args.command == 'base':
        if args.base_action == 'build':
            bundles.build_base(args.iso.resolve(), args.output.resolve())
        else:
            data, checksum = bundles.describe(args.bundle)
            print(json.dumps({'sha256': checksum, **data}, indent=2))
        return 0
    if args.command == 'init':
        if args.output.exists():
            raise ValueError('manifest already exists; nothing changed')
        _, checksum = bundles.describe(args.base)
        data = {'schema': SCHEMA, 'name': args.name, 'base': {'path': os.path.relpath(args.base.resolve(), args.output.resolve().parent), 'sha256': checksum},
                'resources': {'cpus': 4, 'memory_gb': 8}, 'snapshot': args.snapshot,
                'profiles': args.profile, 'packages': [], 'provision': [], 'ports': [],
                'auto_ports': True, 'idle_minutes': None, 'ssh_agent': False, 'interop': []}
        write_json(args.output, data)
        try:
            load(args.output)
        except BaseException:
            args.output.unlink()
            raise
        print('Created ' + str(args.output) + '; commit it and the generated lock file.')
        return 0
    if args.command == 'list':
        entries = environments()
        if args.json:
            print(json.dumps(entries, indent=2))
        else:
            for entry in entries:
                print(f'{entry["name"]:24} {entry["status"]:8} {entry["mode"] or ""}')
        return 0
    path = manifest_path(args.manifest)
    if args.command in ('create', 'lock'):
        if not path:
            raise ValueError('uvm.json not found; run uvm init --base BUNDLE first')
        if args.command == 'create':
            create(path, args.name, args.locked)
        else:
            name = 'lock-' + secrets.token_hex(6)
            vm = None
            try:
                vm = create(path, name, update=True)
            finally:
                if vm:
                    rt.stop(vm)
                    if not rt.disk_busy(vm):
                        shutil.rmtree(vm)
        return 0
    if args.command == 'import':
        data, _ = bundles.describe(args.bundle)
        if data['kind'] != 'environment' or not data.get('manifest'):
            raise ValueError('import expects an environment export, not a base')
        vm = bundles.create(args.bundle, data['manifest'], args.name, imported=True)
        print('Imported ' + str(vm) + '; credentials will rotate at first boot.')
        return 0
    vm = selected(args, path)
    command = args.command or 'shell'
    if command == 'up':
        rt.ensure_up(vm)
    elif command == 'stop':
        rt.stop(vm, args.force)
    elif command in ('run', 'docker', 'shell'):
        if command == 'shell':
            arguments = ['/bin/bash', '-l']
        else:
            arguments = args.argv[1:] if args.argv[:1] == ['--'] else args.argv
            if command == 'docker':
                arguments = ['docker', *arguments]
            if not arguments:
                raise ValueError('uvm run needs a command after --')
        return execute(vm, arguments, getattr(args, 'cwd', None), getattr(args, 'agent', False), getattr(args, 'root', False))
    elif command == 'code':
        integrate.editor(vm)
    elif command == 'docker-context':
        print(integrate.docker_context(vm, args.use))
    elif command == 'ssh-config':
        _, file = integrate.ssh_config(vm, args.install)
        print(file.read_text(), end='')
    elif command == 'ports':
        state = rt.ensure_up(vm)
        for port in state['ports']:
            print(f'127.0.0.1:{port["host"]} → Linux:{port["guest"]}')
        for port in state['conflicts']:
            print(f'CONFLICT 127.0.0.1:{port} is already in use', file=sys.stderr)
        return int(bool(state['conflicts']))
    elif command == 'status':
        metadata = rt.config(vm)
        state = rt.live(vm)
        result = {'name': metadata['name'], 'status': 'running' if state else 'stopped', 'runtime': state}
        print(json.dumps(result, indent=2) if args.json else f'{metadata["name"]}: {result["status"]}')
    elif command == 'export':
        print('Export SHA-256: ' + bundles.export(vm, args.output))
    elif command == 'clone':
        import tempfile
        with tempfile.TemporaryDirectory(prefix='uvm-clone-') as folder:
            bundle = Path(folder) / 'environment'
            bundles.export(vm, bundle)
            metadata = rt.config(vm)
            clone = bundles.create(bundle, metadata['manifest'], args.name, imported=True)
            print('Cloned to ' + str(clone))
    elif command == 'sync':
        rt.ensure_up(vm)
        metadata = rt.config(vm)
        source = args.source or (path.parent if path else None)
        if not source or not source.is_dir():
            raise ValueError('choose the Mac project directory with uvm sync SOURCE')
        target = f'/home/{metadata["user"]}/Projects/{metadata["manifest"]["name"]}'
        producer = subprocess.Popen(['tar', '--exclude=node_modules', '--exclude=.venv', '--exclude=.DS_Store', '-cf', '-', '-C', str(source), '.'], stdout=subprocess.PIPE)
        consumer = subprocess.run(rt.ssh_args(vm) + ['tar --no-same-owner -xf - -C ' + shlex.quote(target)], stdin=producer.stdout)
        producer.stdout.close()
        if producer.wait() or consumer.returncode:
            raise RuntimeError('project transfer failed')
    elif command in ('verify', 'provision'):
        rt.ensure_up(vm)
        definition = path or vm / 'definition/uvm.json'
        settings, inputs, packages = load(definition)
        lock = json.loads((vm / 'uvm.lock.json').read_text())
        check_lock(lock, inputs)
        if command == 'provision':
            apply(vm, definition, inputs, packages, lock)
        else:
            verify(vm, lock)
            print('Verified base identity, manifest, scripts, packages and pinned container images.')
    elif command == 'desktop':
        rt.ensure_up(vm, desktop=True)
        print('Desktop opened. Terminals, editor connections and localhost forwarding remain available.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('uvm: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
