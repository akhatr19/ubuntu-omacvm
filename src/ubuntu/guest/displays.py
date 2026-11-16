#!/usr/bin/python3
"""Map Ubuntu's Mutter displays to the host's logical display layout."""
import json
import os
import re
import sys
from gi.repository import Gio, GLib

NAME = 'org.gnome.Mutter.DisplayConfig'
proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE,
    None, NAME, '/org/gnome/Mutter/DisplayConfig', NAME, None)
fd = os.open('/dev/virtio-ports/org.omacvm.display', os.O_RDWR | os.O_NONBLOCK)
loop = GLib.MainLoop()
buffer = bytearray()
layout = []
pending = 0


def send(message):
    data = json.dumps(message, separators=(',', ':')).encode() + b'\n'
    if os.write(fd, data) != len(data):
        raise RuntimeError('display port write incomplete')


def refresh():
    global pending
    pending = 0
    serial, monitors, logical, properties = proxy.call_sync(
        'GetCurrentState', None, Gio.DBusCallFlags.NONE, 5000, None).unpack()
    modes = {spec[0]: available for spec, available, _props in monitors}
    report = []
    current = []
    for x, y, scale, transform, primary, specs, _props in logical:
        for spec in specs:
            mode = next(m for m in modes[spec[0]] if m[-1].get('is-current'))
            w, h = mode[1:3]
            if transform % 2: w, h = h, w
            report.append(dict(name=spec[0], x=x, y=y, width=round(w / scale, 3), height=round(h / scale, 3)))
            current.append((x, y, scale, transform, primary, [(spec[0], mode[0], {})]))
    send({'monitors': report})
    if not layout:
        return False
    wanted = []
    for i, output in enumerate(layout):
        available = modes.get(output['output'])
        if not available:
            return False  # Wait for Mutter's hotplug signal, not a polling loop.
        w, h = output['width'] * output['scale'], output['height'] * output['scale']
        mode = min(available, key=lambda m: (abs(m[1] - w) + abs(m[2] - h), -m[3]))
        scale = min(mode[5], key=lambda s: abs(s - output['scale']))
        wanted.append((output['x'], output['y'], scale, 0, i == 0,
                       [(output['output'], mode[0], {})]))
    if wanted != current:
        # Temporary: Ubuntu's own saved monitor settings remain intact.
        proxy.call_sync('ApplyMonitorsConfig', GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})',
            (serial, 1, wanted, {'layout-mode': GLib.Variant('u', 1)})),
            Gio.DBusCallFlags.NONE, 5000, None)
    return False


def schedule(*_args):
    global pending
    if pending: GLib.source_remove(pending)
    pending = GLib.timeout_add(200, guarded(refresh))


def receive(_fd, condition):
    global layout
    if condition & (GLib.IO_HUP | GLib.IO_ERR):
        raise RuntimeError('display port disconnected')
    chunk = os.read(fd, 65536)
    if not chunk: raise RuntimeError('display port closed')
    buffer.extend(chunk)
    if len(buffer) > 65536: raise ValueError('display message too large')
    while b'\n' in buffer:
        line, _, rest = buffer.partition(b'\n')
        buffer[:] = rest
        message = json.loads(line)
        candidate = message.get('layout') if isinstance(message, dict) else None
        if not isinstance(candidate, list) or not 1 <= len(candidate) <= 5: continue
        if any(not isinstance(m, dict) or not re.fullmatch(r'Virtual-[1-5]', str(m.get('output', '')))
               or any(type(m.get(k)) is not int or not -65536 <= m[k] <= 65536 for k in ('x', 'y'))
               or any(type(m.get(k)) is not int or not 1 <= m[k] <= 16384 for k in ('width', 'height'))
               or type(m.get('scale')) not in (int, float) or not 1 <= m['scale'] <= 4 for m in candidate):
            continue
        if len({m['output'] for m in candidate}) != len(candidate): continue
        layout = candidate
        schedule()
    return True


def guarded(callback):
    def run(*args):
        try:
            return callback(*args)
        except (OSError, ValueError, RuntimeError, GLib.Error) as error:
            print(f'UbuntuVM displays: {error}', file=sys.stderr, flush=True)
            loop.quit()
            return False
    return run


proxy.connect('g-signal', lambda _p, _s, name, _a: schedule() if name == 'MonitorsChanged' else None)
GLib.io_add_watch(fd, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, guarded(receive))
send({'hello': 1, 'external': True, 'pause': 0})
schedule()
loop.run()
os.close(fd)
sys.exit(1)
