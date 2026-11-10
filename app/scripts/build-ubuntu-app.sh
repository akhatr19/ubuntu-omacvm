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
# Serialize allocation: successful and failed packages never reuse a build number.
LOCK=$R/app/.build/ubuntu-build-number.lock
mkdir "$LOCK" || { echo 'Another Ubuntu package build is allocating a number' >&2; exit 1; }
trap 'rm -rf "$T"; rmdir "$LOCK"' EXIT
BUILD=$(python3 - "$R/app/.build/ubuntu-build-number" <<'PYBUILD'
import pathlib, plistlib, sys
counter = pathlib.Path(sys.argv[1])
numbers = [int(counter.read_text())] if counter.exists() else [0]
for folder in (pathlib.Path('/Applications'), pathlib.Path.home() / 'Applications'):
    for app in folder.glob('*.app'):
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') == 'org.omacvm.ubuntu' and info.get('UbuntuVMDevBuild'):
                numbers.append(int(info['CFBundleVersion']))
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            pass
number = max(numbers) + 1
counter.write_text(str(number) + '\n')
print(number)
PYBUILD
)
APP=$T/UbuntuVM.app
C=$APP/Contents
ditto "$BASE" "$APP"
cp "$BIN/OmacVM" "$C/MacOS/OmacVM"
cp "$R"/app/scripts/*.sh "$C/Resources/scripts/"
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.build --exclude=build --exclude=__pycache__ --exclude='*.pyc' -czf - -C "$R" omacvm uvm src README.md CHANGELOG.md docs |
  tar -xzf - -C "$C/Resources/omacvm"
COMMIT=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$COMMIT" > "$C/Resources/omacvm/COMMIT"
ID=${OMACVM_UBUNTU_BUNDLE_ID:-org.omacvm.ubuntu}
[[ $ID == org.omacvm.ubuntu || $ID == org.omacvm.ubuntu.* ]] || exit 2
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1' "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$C/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :UbuntuVMDevBuild bool true' "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$C/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName UbuntuVM' "$C/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName UbuntuVM' "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NSLocalNetworkUsageDescription UbuntuVM connects Ubuntu to the network. Optional LAN SSH and port forwards let other devices reach the services you publish." "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NSBluetoothAlwaysUsageDescription UbuntuVM optional integrations access Bluetooth only when you enable them." "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :OmacVMCommit $COMMIT" "$C/Info.plist"
mkdir "$T/UbuntuVM.iconset"
for n in 16 32 128 256 512; do
  sips -s format png -z "$n" "$n" "$R/app/app/UbuntuVM.svg" --out "$T/UbuntuVM.iconset/icon_${n}x${n}.png" >/dev/null
  sips -s format png -z "$((n * 2))" "$((n * 2))" "$R/app/app/UbuntuVM.svg" --out "$T/UbuntuVM.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$T/UbuntuVM.iconset" -o "$C/Resources/OmacVM.icns"
HELPER=$C/Helpers/OmacVMGestures.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleName UbuntuVM Gestures' "$HELPER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string UbuntuVM Gestures' "$HELPER/Contents/Info.plist" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName UbuntuVM Gestures' "$HELPER/Contents/Info.plist"
cp "$C/Resources/OmacVM.icns" "$HELPER/Contents/Resources/OmacVM.icns"
"$R/src/lib/sign.sh" "$HELPER" org.omacvm.gestures
"$R/app/scripts/sign-app.sh" "$APP" "$ID"
mkdir -p "$(dirname "$OUT")"
mv "$APP" "$OUT"
echo "Built UbuntuVM 0.1 Dev Build #$BUILD at $OUT"
