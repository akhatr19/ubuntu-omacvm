#!/bin/bash
# Build only the patched Venus ICD in its own prefix; Ubuntu's Mesa stays.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PREFIX=/opt/omacvm-venus
STAMP=$PREFIX/omacvm-build
VERSION=26.2.4
INPUT=$(sha256sum "$0" "$R/app/guest/venus/PKGBUILD" "$R"/app/guest/venus/patches/*.patch | sha256sum | cut -d' ' -f1)
[[ $(cat "$STAMP" 2>/dev/null) != "$INPUT" ]] || exit 0
apt-get install -y --no-install-recommends build-essential meson ninja-build pkg-config \
  python3-mako python3-yaml python3-packaging bison flex glslang-tools \
  libexpat1-dev libdrm-dev libwayland-dev wayland-protocols libx11-dev libx11-xcb-dev libxext-dev \
  libxfixes-dev libxrandr-dev libxxf86vm-dev libxcb-randr0-dev libxcb-keysyms1-dev \
  libxcb-shm0-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-glx0-dev libxcb-present-dev libxcb-sync-dev libxshmfence-dev \
  libzstd-dev zlib1g-dev libsystemd-dev libudev-dev libdisplay-info-dev libvulkan-dev curl ca-certificates xz-utils
B=$(mktemp -d /var/tmp/omacvm-venus.XXXXXX)
trap 'rm -rf "$B"' EXIT
curl -fL --retry 3 --retry-all-errors -o "$B/mesa.tar.xz" "https://archive.mesa3d.org/mesa-$VERSION.tar.xz"
echo "bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9  $B/mesa.tar.xz" | sha256sum -c -
tar -xJf "$B/mesa.tar.xz" -C "$B"
for p in mesa-venus-opaque-fd-semaphores mesa-venus-tls-after-unload; do
  patch -d "$B/mesa-$VERSION" -p1 < "$R/app/guest/venus/patches/$p.patch"
done
meson setup "$B/build" "$B/mesa-$VERSION" --prefix "$PREFIX" --libdir lib \
  --buildtype release --wrap-mode nodownload -Dplatforms=x11,wayland \
  -Dgallium-drivers= -Dvulkan-drivers=virtio -Dvulkan-layers= \
  -Dvulkan-loader-rpath= -Dvulkan-manifest-per-architecture=false \
  -Dopengl=false -Dglx=disabled -Degl=disabled -Dgbm=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Dvideo-codecs= \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dandroid-libbacktrace=disabled -Dmicrosoft-clc=disabled
meson compile -C "$B/build" -j 4
meson install -C "$B/build"
# Prefer our patched Venus; leave every other Vulkan ICD available.
install -d /etc/vulkan/icd.d
python3 - "$PREFIX" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads((p / "share/vulkan/icd.d/virtio_icd.json").read_text())
data["ICD"]["library_path"] = str(p / "lib/libvulkan_virtio.so")
pathlib.Path("/etc/vulkan/icd.d/omacvm_venus_icd.json").write_text(json.dumps(data))
PY
printf '%s\n' "$INPUT" > "$STAMP"
