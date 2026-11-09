#!/bin/bash
# Reuse the verified upstream 3.4.1 runtime; compile and package the Ubuntu launcher.
# Usage: build-ubuntu-app.sh UPSTREAM_OmacVM.app NEW_OUTPUT.app
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
BASE=${1:?upstream OmacVM.app required}
OUT=${2:?new output .app path required}
UPSTREAM=fc0dc8f2140190ba7ed6718f14ac65196410242c
[[ ! -e $OUT && $OUT == *.app ]] || { echo 'Output must be a new .app path' >&2; exit 2; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :OmacVMCommit' "$BASE/Contents/Info.plist") == "$UPSTREAM" ]] || {
  echo 'Use the official OmacVM 3.4.1 app (runtime sources must match)' >&2; exit 2;
}
git -C "$R" diff --quiet "$UPSTREAM" -- app/runtime || {
  echo 'Runtime sources changed: build a matching runtime first' >&2; exit 2;
}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build --package-path "$R/app/app" --disable-sandbox --product OmacVM
BIN=$(swift build --package-path "$R/app/app" --show-bin-path)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
APP=$T/UbuntuVM.app
C=$APP/Contents
ditto "$BASE" "$APP"
cp "$BIN/OmacVM" "$C/MacOS/OmacVM"
cp "$R"/app/scripts/*.sh "$C/Resources/scripts/"
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.build --exclude=build -czf - -C "$R" omacvm src README.md CHANGELOG.md docs |
  tar -xzf - -C "$C/Resources/omacvm"
COMMIT=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$COMMIT" > "$C/Resources/omacvm/COMMIT"
ID=${OMACVM_UBUNTU_BUNDLE_ID:-org.omacvm.ubuntu}
[[ $ID == org.omacvm.ubuntu || $ID == org.omacvm.ubuntu.* ]] || exit 2
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$C/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName UbuntuVM' "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :OmacVMCommit $COMMIT" "$C/Info.plist"
mkdir "$T/UbuntuVM.iconset"
for n in 16 32 128 256 512; do
  sips -s format png -z "$n" "$n" "$R/app/app/UbuntuVM.svg" --out "$T/UbuntuVM.iconset/icon_${n}x${n}.png" >/dev/null
  sips -s format png -z "$((n * 2))" "$((n * 2))" "$R/app/app/UbuntuVM.svg" --out "$T/UbuntuVM.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$T/UbuntuVM.iconset" -o "$C/Resources/OmacVM.icns"
"$R/app/scripts/sign-app.sh" "$APP" "$ID"
mkdir -p "$(dirname "$OUT")"
mv "$APP" "$OUT"
echo "Built $OUT"
