#!/bin/bash
# Human-invoked Mac setup: install the packaged Gestures helper, not Bridge/Omanotch.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
HELPER=$HERE/../../Helpers/OmacVMGestures.app
[[ -d $HELPER ]] || HELPER=$HERE/../dist/UbuntuVM.app/Contents/Helpers/OmacVMGestures.app
[[ -d $HELPER ]] || die 'Build UbuntuVM.app first (the signed Gestures helper is required)'
TOKEN="$HOME/Library/Application Support/omacvm-bridge/token"
if [[ ! -f $TOKEN ]]; then
  mkdir -p "$(dirname "$TOKEN")"
  chmod 700 "$(dirname "$TOKEN")"
  (umask 077; openssl rand -hex 32 > "$TOKEN")
fi
[[ $(tr -d '\n' < "$TOKEN") =~ ^[0-9a-f]{64}$ ]] || die 'The existing gestures token is invalid; it was left unchanged'
"$OMACVM_SRC/gestures/mac/install.sh" --prebuilt "$HELPER" --app-name UbuntuVMGestures.app
echo 'Allow UbuntuVM Gestures in macOS Privacy & Security → Accessibility and Input Monitoring.'
