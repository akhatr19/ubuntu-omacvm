#!/usr/bin/python3
"""GNOME selection backend for the existing, bounded clipboard protocol."""
import base64
import json
import os
import sys
from gi.repository import Gio, GLib

sys.path.insert(0, '/usr/local/lib/omacvm')
from clipboard_protocol import ClipboardSync, decode_message, MAX_LINE_BYTES

fd = os.open('/dev/virtio-ports/org.omacvm.clipboard', os.O_RDWR | os.O_NONBLOCK)
proxy = Gio.DBusProxy.new_for_bus_sync(
    Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, 'org.gnome.Shell',
    '/org/omacvm/Clipboard', 'org.omacvm.Clipboard', None)
loop = GLib.MainLoop()
inbox = bytearray()
outbox = bytearray()
writing = False


def write_ready(_fd, condition):
    global writing
    if condition & (GLib.IO_HUP | GLib.IO_ERR):
        raise RuntimeError('clipboard port disconnected')
    try:
        del outbox[:os.write(fd, outbox)]
    except BlockingIOError:
        return True
    writing = bool(outbox)
    return writing


def send(data):
    global writing
    if len(outbox) + len(data) > 2 * MAX_LINE_BYTES:
        raise RuntimeError('clipboard output queue exceeded limit')
    outbox.extend(data)
    if not writing:
        writing = True
        GLib.io_add_watch(fd, GLib.IO_OUT | GLib.IO_HUP | GLib.IO_ERR, guarded(write_ready))


def set_clipboard(mime, payload):
    proxy.call('Set', GLib.Variant('(ss)', (mime, base64.b64encode(payload).decode())),
               Gio.DBusCallFlags.NONE, 5000, None, None)


def changed(_proxy, _sender, name, args):
    if name == 'Changed':
        mime, encoded = args.unpack()
        decoded = decode_message(json.dumps({'type': 'clipboard', 'format': mime, 'data': encoded}).encode())
        if decoded:
            sync.guest_changed(*decoded)


def read_ready(_fd, condition):
    if condition & (GLib.IO_HUP | GLib.IO_ERR):
        raise RuntimeError('clipboard port disconnected')
    chunk = os.read(fd, 65536)
    if not chunk:
        raise RuntimeError('clipboard port closed')
    inbox.extend(chunk)
    if len(inbox) > MAX_LINE_BYTES:
        raise ValueError('clipboard message exceeded limit')
    while b'\n' in inbox:
        line, _, rest = inbox.partition(b'\n')
        inbox[:] = rest
        decoded = decode_message(line)
        if decoded:
            sync.host_changed(*decoded)
    return True


def guarded(callback):
    def run(*args):
        try:
            return callback(*args)
        except (OSError, ValueError, RuntimeError, GLib.Error) as error:
            print(f'UbuntuVM clipboard: {error}', file=sys.stderr, flush=True)
            loop.quit()
            return False
    return run


sync = ClipboardSync(send, set_clipboard)
proxy.connect('g-signal', guarded(changed))
GLib.io_add_watch(fd, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, guarded(read_ready))
proxy.call_sync('Sync', None, Gio.DBusCallFlags.NONE, 5000, None)
send(b'{"type":"sync"}\n')
loop.run()
os.close(fd)
sys.exit(1)  # systemd reconnects after a port or extension restart
