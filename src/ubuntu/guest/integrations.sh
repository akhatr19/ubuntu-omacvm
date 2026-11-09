#!/bin/bash
# GNOME agents: keep the proven host protocols and distribution-neutral helpers.
set -euo pipefail
U=${1:?desktop user}
H=$(getent passwd "$U" | cut -d: -f6)
R=$(cd "$(dirname "$0")/../.." && pwd)
A=$R/app/guest
source "$R/guest/home-files.sh"
install -Dm644 "$A/70-omacvm-clipboard.rules" /etc/udev/rules.d/70-omacvm-clipboard.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=virtio-ports
for name in media audio-latency mac-folder; do
  install -m755 "$A/omacvm-$name" /usr/local/bin/
done
install -m644 "$A/omacvm-mac-folder.service" /etc/systemd/system/
install -Dm644 "$A/omacvm-clipboard" /usr/local/lib/omacvm/clipboard_protocol.py
install -m755 "$R/ubuntu/guest/clipboard.py" /usr/local/bin/omacvm-clipboard
install -m755 "$R/ubuntu/guest/displays.py" /usr/local/bin/omacvm-displays
for name in clipboard displays media audio-latency; do
  sed 's/Omarchy/Ubuntu/g' "$A/omacvm-$name.service" > "/etc/systemd/user/omacvm-$name.service"
  systemctl --global enable "omacvm-$name.service"
done
install -m755 "$R/ubuntu/guest/open-settings" /usr/local/lib/omacvm/open-settings
EXT=clipboard@ubuntu.omacvm.org
install -d "/usr/share/gnome-shell/extensions/$EXT"
install -m644 "$R/ubuntu/guest/clipboard-extension/"* "/usr/share/gnome-shell/extensions/$EXT/"
# GSettings changes and user-service operations run as the desktop user.
# Do not replace the person's existing enabled-extension list.
home_run env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS dbus-run-session -- python3 - <<'PY'
from gi.repository import Gio
settings = Gio.Settings.new('org.gnome.shell')
extensions = settings.get_strv('enabled-extensions')
name = 'clipboard@ubuntu.omacvm.org'
if name not in extensions:
    settings.set_strv('enabled-extensions', extensions + [name])
    Gio.Settings.sync()
PY
systemctl daemon-reload
systemctl enable --now omacvm-mac-folder.service
if [[ -d /run/user/$(id -u "$U") ]]; then
  home_run env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$U")/bus" \
    systemctl --user daemon-reload
fi

source /etc/omacvm/env
"$R/battery/guest/install.sh" "${OMACVM_FEATURE_battery:-off}"
"$R/camera/guest/install.sh" "$U" app "${OMACVM_FEATURE_camera:-off}"
