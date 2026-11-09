#!/bin/bash
# Ubuntu-specific guest setup: no pacman, Omarchy shell or Hyprland config.
set -euo pipefail
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.10 && $(dpkg --print-architecture) == arm64 ]] || { echo "Ubuntu 26.10 ARM64 required" >&2; exit 2; }
(( EUID == 0 )) || { echo "run as root" >&2; exit 2; }
U=${1:?usage: install.sh DESKTOP_USER}
id "$U" >/dev/null
R=$(cd "$(dirname "$0")/../.." && pwd)
A=$R/app/guest
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends qemu-guest-agent openssh-server python3 python3-gi \
  build-essential libva-dev libegl-dev libglvnd-dev mesa-va-drivers mesa-vulkan-drivers \
  mesa-opencl-icd vulkan-tools clinfo vainfo mesa-utils mpv ffmpeg systemd-zram-generator
install -d /etc/omacvm
printf 'OMACVM_USER=%s\nOMACVM_VM_TYPE=app\nOMACVM_GUEST_OS=ubuntu\nOMACVM_GRAPHICS=vulkan\n' "$U" > /etc/omacvm/env
"$R/memory/guest/install.sh"
install -Dm755 "$A/omacvm-smbios" /usr/local/lib/omacvm/omacvm-smbios
install -m755 "$A/omacvm-app-host" /usr/local/bin/
install -m644 "$A/omacvm-app-host.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now omacvm-app-host.service
systemctl start --no-block qemu-guest-agent
MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
VA=/usr/lib/$MULTIARCH/dri/virtio_gpu_drv_video.so
[[ -f $VA ]] || { echo "Ubuntu's mesa-va-drivers lacks the virtio GPU VA driver" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cc -shared -fPIC -O2 "-DMESA_DRIVER=\"$VA\"" -o "$T/omacvm_drv_video.so" "$A/omacvm_drv_video.c" -ldl
cc -shared -fPIC -O2 -fvisibility=hidden -Wl,-soname,libEGL_omacvm.so.0 \
  -o "$T/libEGL_omacvm.so.0" "$A/omacvm_egl.c" -ldl
install -Dm755 "$T/omacvm_drv_video.so" /usr/local/lib/dri/omacvm_drv_video.so
install -m755 "$T/libEGL_omacvm.so.0" /usr/local/lib/
install -Dm644 "$A/10-omacvm-egl.json" /etc/glvnd/egl_vendor.d/10_omacvm.json
install -Dm644 "$A/90-omacvm-video.conf" /etc/environment.d/90-omacvm-video.conf
echo /usr/local/lib/dri > /etc/ld.so.conf.d/omacvm-video.conf
ldconfig
"$(dirname "$0")/venus.sh"
printf 'RUSTICL_ENABLE=zink\nVK_DRIVER_FILES=/etc/vulkan/icd.d/omacvm_venus_icd.json\n' > /etc/environment.d/90-omacvm-opencl.conf
install -Dm755 "$(dirname "$0")/omacvm-browser" /usr/local/bin/omacvm-browser
ln -sf omacvm-browser /usr/local/bin/omacvm-browser-webgpu
install -Dm644 "$(dirname "$0")/omacvm-browser.desktop" /usr/local/share/applications/omacvm-browser.desktop
install -Dm644 "$(dirname "$0")/omacvm-browser-webgpu.desktop" /usr/local/share/applications/omacvm-browser-webgpu.desktop
if ! command -v google-chrome-stable >/dev/null; then
  curl -fL --retry 3 -o "$T/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
  apt-get install -y "$T/chrome.deb"
fi
install -d /etc/mpv
printf 'vo=gpu\ngpu-api=opengl\nhwdec=vaapi\n' > /etc/mpv/omacvm.conf
# mpv reads *.conf only when included; a drop-in avoids replacing Ubuntu/user settings.
touch /etc/mpv/mpv.conf
grep -qxF 'include=/etc/mpv/omacvm.conf' /etc/mpv/mpv.conf || echo 'include=/etc/mpv/omacvm.conf' >> /etc/mpv/mpv.conf
echo "Ubuntu guest setup installed; restart before testing graphics and compute"
