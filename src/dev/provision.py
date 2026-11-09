"""Snapshot-pinned apt provisioning and input/output verification."""
import base64
import json
from pathlib import Path
import shlex

from manifest import check_lock, write_json
from runtime import ROOT, config, run, ssh, ssh_args


def install_tools(vm):
    metadata = config(vm)
    user = metadata['user']
    for name in ('uvm-exec', 'uvm-host'):
        data = (ROOT / 'src/dev/guest' / name).read_bytes()
        ssh(vm, f'cat > /usr/local/bin/{name}; chmod 755 /usr/local/bin/{name}', root=True, input=data)
    rule = f'SUBSYSTEM=="virtio-ports", ATTR{{name}}=="org.ubuntu.vm.host", OWNER="{user}", MODE="0600"\n'
    ssh(vm, "cat > /etc/udev/rules.d/71-uvm-host.rules; udevadm control --reload-rules; udevadm trigger --subsystem-match=virtio-ports",
        root=True, input=rule.encode())
    ssh(vm, 'usermod -aG render,video ' + shlex.quote(user), root=True)
    if metadata['manifest']['desktop_autologin']:
        script = '''import configparser
p=configparser.ConfigParser(); p.optionxform=str
p.read('/etc/gdm3/custom.conf')
if not p.has_section('daemon'): p.add_section('daemon')
p.set('daemon','AutomaticLoginEnable','true'); p.set('daemon','AutomaticLogin',%r)
with open('/etc/gdm3/custom.conf','w') as f: p.write(f)
''' % user
        ssh(vm, 'python3 -', root=True, input=script.encode())


def inventory(vm):
    output = ssh(vm, "dpkg-query -W -f='${db:Status-Status}\\t${binary:Package}=${Version}\\n'", root=True, capture_output=True).stdout.decode()
    return sorted(line.split('\t', 1)[1] for line in output.splitlines() if line.startswith('installed\t'))


def image_id(vm, image):
    return ssh(vm, 'docker image inspect --format {{.Id}} ' + shlex.quote(image),
               root=True, capture_output=True).stdout.decode().strip()


def verify(vm, locked):
    metadata = config(vm)
    for field in ('base_sha256', 'runtime_sha256'):
        if metadata[field] != locked[field]:
            raise ValueError('environment provenance differs from the lock: ' + field)
    if inventory(vm) != locked['apt_inventory']:
        raise ValueError('installed packages differ from the locked inventory')
    for image, identity in locked.get('images', {}).items():
        if image_id(vm, image) != identity:
            raise ValueError('container image differs from the lock: ' + image)


def apply(vm, manifest_path, inputs, packages, locked=None):
    metadata = config(vm)
    settings = metadata['manifest']
    install_tools(vm)
    if locked:
        check_lock(locked, inputs)
    selections = locked['apt_requested'] if locked else packages
    payload = base64.b64encode(json.dumps({'snapshot': settings['snapshot'], 'packages': selections,
                                           'docker': 'docker' in settings['profiles'], 'user': metadata['user']}).encode()).decode()
    script = '''import base64, json, os, pathlib, subprocess
p=json.loads(base64.b64decode(%r))
os.environ['DEBIAN_FRONTEND']='noninteractive'
sources=pathlib.Path('/etc/apt/sources.list.d/uvm.sources')
sources.write_text('Types: deb\\nURIs: https://snapshot.ubuntu.com/ubuntu/'+p['snapshot']+'/\\nSuites: stonking stonking-updates stonking-security\\nComponents: main universe restricted multiverse\\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\\nCheck-Valid-Until: no\\n')
options=['-o','Dir::Etc::sourcelist='+str(sources),'-o','Dir::Etc::sourceparts=-',
 '-o','APT::Update::Error-Mode=any','-o','Acquire::Retries=3','-o','Acquire::Languages=none']
subprocess.run(['apt-get',*options,'update'],check=True)
if p['packages']:
 subprocess.run(['apt-get',*options,'install','-y','--no-install-recommends',*p['packages']],check=True)
if p['docker']:
 subprocess.run(['usermod','-aG','docker',p['user']],check=True)
 subprocess.run(['systemctl','enable','--now','docker'],check=True)
''' % payload
    ssh(vm, 'python3 -', root=True, input=script.encode())
    images = {}
    for image in settings['images']:
        # The registry digest selects immutable bytes; never resolve mutable tags here.
        ssh(vm, 'docker pull --platform linux/arm64 ' + shlex.quote(image), root=True)
        images[image] = image_id(vm, image)
    if locked and images != locked.get('images', {}):
        raise ValueError('container image identities differ from the lock')
    project = f'/home/{metadata["user"]}/Projects/{settings["name"]}'
    ssh(vm, 'mkdir -p ' + shlex.quote(project))
    source = settings.get('git')
    if source:
        command = f'''set -e
cd {shlex.quote(project)}
if [ ! -d .git ]; then
 git init -q
 git remote add origin {shlex.quote(source['url'])}
 git fetch -q --depth=1 origin {source['commit']}
 git checkout -q --detach {source['commit']}
fi
[ "$(git rev-parse HEAD)" = {source['commit']} ] || {{ echo 'Project revision differs; use a fresh environment to replay' >&2; exit 1; }}
'''
        run(ssh_args(vm, agent=settings['ssh_agent']) + [command])
    for path in settings['provision']:
        data = (Path(manifest_path).parent / path).read_bytes()
        target = '/tmp/uvm-provision-' + inputs['scripts'][path] + '.sh'
        command = f'umask 077; cat > {target}; cd {shlex.quote(project)} && /bin/bash {target}; status=$?; rm -f {target}; exit $status'
        run(ssh_args(vm, agent=settings['ssh_agent']) + [command], input=data)
    actual = inventory(vm)
    if locked and actual != locked['apt_inventory']:
        raise ValueError('installed package inventory differs from the lock; no new lock was written')
    versions = dict(item.split('=', 1) for item in actual)
    requested = []
    for package in packages:
        name = package.split('=', 1)[0]
        version = versions.get(name) or versions.get(name + ':arm64')
        if not version:
            raise ValueError(f'requested package is not installed: {name}')
        requested.append(name + '=' + version)
    result = {**inputs, 'runtime_commit': metadata['runtime_commit'], 'runtime_sha256': metadata['runtime_sha256'],
              'apt_requested': requested, 'apt_inventory': actual, 'images': images}
    write_json(vm / 'uvm.lock.json', result)
    return result
