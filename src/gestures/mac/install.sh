#!/bin/bash
# Install OmacVMGestures.app to ~/Applications and start it at login (LaunchAgent).
#   ./install.sh [--prebuilt APP] [--keys-only] [-v] [--record]
# --prebuilt: that copy (OmacVM.app's, signed with OmacVM's Developer ID)
# instead of building one here.
# --keys-only: trackpad gestures stay with macOS for every VM; Cmd
# still reaches Omarchy as Super. Otherwise each VM chooses gestures and scroll momentum
# for itself. Diagnostics: -v logs more, --record writes the trackpad's frames
# and macOS's scroll events to ~/Library/Logs/omacvm-input.tsv (scroll momentum analysis,
# docs/experiments/scroll-analysis).
set -euo pipefail
cd "$(dirname "$0")"
ARGS=""; APP=build/OmacVMGestures.app; PRE=0; SAID=""; APP_NAME=OmacVMGestures.app
while (( $# )); do
  case $1 in
    --app-name)
      [[ ${2:-} == UbuntuVMGestures.app ]] || { echo 'unsupported helper app name' >&2; exit 2; }
      APP_NAME=$2; shift 2; continue ;;
    --prebuilt) APP=${2:?--prebuilt APP}; PRE=1; shift 2; continue ;;
    --keys-only|-v|--record) ARGS+="<string>$1</string>"; SAID+="${SAID:+ }$1" ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
(( PRE )) || ./build.sh
source ../../lib/labels.sh   # after the cd above
LABEL=$(omacvm_label gestures)
PL=~/Library/LaunchAgents/$LABEL.plist
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$HOME/Applications/$APP_NAME"
ditto "$APP" "$HOME/Applications/$APP_NAME"
if [[ $APP_NAME == UbuntuVMGestures.app && -d $HOME/Applications/OmacVMGestures.app &&
      $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOME/Applications/OmacVMGestures.app/Contents/Info.plist" 2>/dev/null) == "$LABEL" ]]; then
  rm -rf "$HOME/Applications/OmacVMGestures.app"
fi
# The app it came from was already let in; launchd does not ask again.
xattr -dr com.apple.quarantine "$HOME/Applications/$APP_NAME" 2>/dev/null || true
cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/$APP_NAME/Contents/MacOS/omacvm-gestures</string>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/omacvm-gestures.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omacvm-gestures.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PL"
echo "installed${SAID:+ ($SAID)}; log: ~/Library/Logs/omacvm-gestures.log"
