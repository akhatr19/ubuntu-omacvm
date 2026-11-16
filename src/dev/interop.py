"""Opt-in, bounded host actions. No shell command or host path comes from the guest."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.parse

MAX_BYTES = 16 * 1024 * 1024
MAX_LINE = MAX_BYTES * 4 // 3 + 4096


def request_integer(value):
    if len(value) > 16:
        raise ValueError('request integer is too large')
    return int(value)


def action(message, capabilities, destination):
    if not isinstance(message, dict) or type(message.get('id')) is not int or not 0 <= message['id'] < 2 ** 53:
        raise ValueError('invalid host request')
    method = message.get('action')
    if method == 'open' and 'browser' in capabilities:
        url = message.get('url')
        if not isinstance(url, str) or len(url) > 8192:
            raise ValueError('invalid URL')
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or any(ord(c) < 32 for c in url):
            raise ValueError('only http/https browser URLs are supported')
        subprocess.run(['/usr/bin/open', url], check=True)
        return {}
    if method == 'paste' and 'clipboard' in capabilities:
        reader = subprocess.Popen(['/usr/bin/pbpaste'], stdout=subprocess.PIPE)
        data = reader.stdout.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            reader.kill()
            reader.wait()
            raise ValueError('clipboard is too large')
        if reader.wait() != 0:
            raise ValueError('Mac clipboard could not be read')
        return {'data': base64.b64encode(data).decode()}
    if method in ('copy', 'export'):
        capability = 'clipboard' if method == 'copy' else 'export'
        if capability not in capabilities:
            raise ValueError(f'{capability} interop is not enabled in the manifest')
        encoded = message.get('data')
        if not isinstance(encoded, str) or len(encoded) > MAX_LINE - 4096:
            raise ValueError('payload is too large')
        data = base64.b64decode(encoded, validate=True)
        if len(data) > MAX_BYTES:
            raise ValueError('payload is too large')
        if method == 'copy':
            data.decode('utf-8')
            subprocess.run(['/usr/bin/pbcopy'], input=data, check=True)
            return {}
        name = message.get('name')
        if not isinstance(name, str) or not name or name in ('.', '..') or len(name.encode()) > 255:
            raise ValueError('invalid export filename')
        if any(c in name for c in ('/', '\\')) or any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError('invalid export filename')
        destination.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            raise ValueError('export destination is a symlink')
        file = None
        for index in range(10000):
            candidate = destination / (name if index == 0 else f'{Path(name).stem} ({index + 1}){Path(name).suffix}')
            try:
                fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                file = candidate
                break
            except FileExistsError:
                continue
        if file is None:
            raise ValueError('no available export filename')
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        subprocess.run(['/usr/bin/open', '-R', str(file)], check=True)
        return {'name': file.name}
    raise ValueError('host action is not enabled in the manifest')


def serve(path, capabilities, destination, stopped):
    """QEMU owns the socket. Reconnect after boot; never open a TCP host API."""
    while not stopped.is_set():
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(1)
                connection.connect(str(path))
                buffer = bytearray()
                total_exported = 0
                next_action = 0
                while not stopped.is_set():
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buffer.extend(chunk)
                    if len(buffer) > MAX_LINE:
                        break
                    while b'\n' in buffer:
                        line, _, remaining = buffer.partition(b'\n')
                        buffer[:] = remaining
                        request = None
                        try:
                            request = json.loads(line, parse_int=request_integer)
                            if not isinstance(request, dict):
                                raise ValueError('host request must be an object')
                            if time.monotonic() < next_action:
                                raise ValueError('host requests are limited to two per second')
                            next_action = time.monotonic() + .5
                            if request.get('action') == 'export':
                                total_exported += len(request.get('data', ''))
                                if total_exported > 1024 * 1024 * 1024:
                                    raise ValueError('export session quota exceeded')
                            result = action(request, capabilities, destination)
                            reply = {'id': request['id'], 'ok': True, **result}
                        except (ValueError, TypeError, RecursionError, OSError, subprocess.SubprocessError) as error:
                            reply = {'id': request.get('id') if isinstance(request, dict) else None,
                                     'ok': False, 'error': str(error)[:300]}
                        connection.sendall(json.dumps(reply).encode() + b'\n')
        except OSError:
            stopped.wait(1)
