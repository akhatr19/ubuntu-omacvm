#!/bin/bash
# Run inside Ubuntu after starting the VM with its accelerated GPU.
set -uo pipefail
fails=0
export VK_DRIVER_FILES=/etc/vulkan/icd.d/omacvm_venus_icd.json
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
check "QEMU guest agent" systemctl is-active --quiet qemu-guest-agent
check "free-page reporting block size" grep -qx 6 /sys/module/page_reporting/parameters/page_reporting_order
check "virtio balloon" test -d /sys/bus/virtio/drivers/virtio_balloon
check "Venus GPU" bash -o pipefail -c 'vulkaninfo --summary 2>/dev/null | grep -E "deviceName.*(Virtio|Venus|Apple)"'
check "OpenCL GPU (Rusticl/Zink)" bash -o pipefail -c 'RUSTICL_ENABLE=zink clinfo -l 2>/dev/null | grep -i zink'
node=$(find /dev/dri -name 'renderD*' -print -quit 2>/dev/null)
check "VA-API hardware decoder" bash -o pipefail -c 'LIBVA_DRIVER_NAME=omacvm LIBVA_DRIVERS_PATH=/usr/local/lib/dri vainfo --display drm --device "$1" 2>&1 | grep -E "VAProfile(H264|VP9).*VAEntrypointVLD"' _ "$node"
check "browser installed" command -v google-chrome-stable
check "GNOME clipboard extension" test -f /usr/share/gnome-shell/extensions/clipboard@ubuntu.omacvm.org/extension.js
for name in clipboard displays media audio-latency; do
  check "$name enabled for desktop sessions" systemctl --global is-enabled --quiet "omacvm-$name.service"
done
check "audio latency utility" command -v pactl
check "shared folder service" systemctl is-enabled --quiet omacvm-mac-folder
source /etc/omacvm/env
[[ ${OMACVM_FEATURE_battery:-off} != on ]] || check "battery module" test -d /sys/module/omacvm_battery
[[ ${OMACVM_FEATURE_camera:-off} != on ]] || check "camera device" test -c /dev/video42
if [[ ${OMACVM_FEATURE_drag_drop:-off} == on ]]; then
  check "Finder drop agent" systemctl --global is-enabled --quiet omacvm-drop
  check "Finder drop share" mountpoint -q /run/omacvm/drop
fi
[[ ${OMACVM_FEATURE_gestures:-off} != on ]] || check "virtual trackpad agent" systemctl is-active --quiet omacvm-gestures
check "WebGPU launcher" test -x /usr/local/bin/omacvm-browser-webgpu
echo "Browser WebGPU dispatch and decoded playback require separate runtime tests; launchers alone do not verify them."
exit "$((fails != 0))"
