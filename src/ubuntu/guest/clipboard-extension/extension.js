import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const XML = `<node><interface name="org.omacvm.Clipboard">
<method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/></method>
<method name="Sync"/>
<signal name="Changed"><arg type="s"/><arg type="s"/></signal>
</interface></node>`;
const TEXT = 'text/plain;charset=utf-8';
const LIMIT = 16 * 1024 * 1024;

export default class Clipboard extends Extension {
    enable() {
        this._generation = 0;
        this._clipboard = St.Clipboard.get_default();
        this._bus = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._bus.export(Gio.DBus.session, '/org/omacvm/Clipboard');
        this._selection = global.display.get_selection();
        this._changed = this._selection.connect('owner-changed', (_s, type) => {
            if (type === 1) this.Sync(); // Meta.SelectionType.CLIPBOARD
        });
    }

    Set(mime, encoded) {
        if (![TEXT, 'image/png'].includes(mime) || encoded.length > Math.ceil(LIMIT / 3) * 4)
            return;
        const bytes = GLib.base64_decode(encoded);
        if (bytes.length && bytes.length <= LIMIT)
            this._clipboard.set_content(St.ClipboardType.CLIPBOARD, mime, new GLib.Bytes(bytes));
    }

    Sync() {
        const generation = ++this._generation;
        const types = this._clipboard.get_mimetypes(St.ClipboardType.CLIPBOARD);
        const mime = types.includes('image/png') ? 'image/png' : types.find(t => t.startsWith('text/plain'));
        if (!mime) return;
        this._clipboard.get_content(St.ClipboardType.CLIPBOARD, mime, (_c, bytes) => {
            if (!this._bus || generation !== this._generation || !bytes || bytes.get_size() > LIMIT)
                return;
            this._bus.emit_signal('Changed', new GLib.Variant('(ss)', [
                mime === 'image/png' ? mime : TEXT, GLib.base64_encode(bytes.get_data()),
            ]));
        });
    }

    disable() {
        ++this._generation;
        this._selection.disconnect(this._changed);
        this._bus.unexport();
        this._bus = null;
        this._clipboard = null;
        this._selection = null;
    }
}
