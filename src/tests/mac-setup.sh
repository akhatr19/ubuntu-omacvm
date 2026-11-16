#!/bin/bash
# Is this Mac set up for an OmacVM.app VM (src/lib/mac-setup.sh): which Mac
# helpers its features need (the map omacvm apply installs by), whether they
# are installed, running and allowed, and whether the VM has this Mac's token
# (its folder's mac-setup record). OmacVM.app asks it before each start
# (src/mac/install.sh --status) and omacvm check prints it as "Mac setup".
# Nothing real is looked at: HOME is a temp folder, pgrep, launchctl and the
# process age are stand-ins (the Mac running this has its own helpers).
#   src/tests/mac-setup.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/Applications" "$T/home/Library/LaunchAgents" "$T/home/Library/Logs" "$T/bin" "$T/state"
export HOME=$T/home
unset OMACVM_TEST_IDENTITY OMACVM_MAC_NOTCH
# pgrep -a -o -u UID -f PATTERN: the pid in state/pid-<helper>, else none.
cat > "$T/bin/pgrep" <<EOF
#!/bin/bash
p=\${!#}
case \$p in
  *"OmacVM Test Bridge"*) f=test-bridge ;; *"OmacVM Test Gestures"*) f=test-gestures ;;
  *OmacVMBridge*) f=bridge ;; *OmacVMGestures*) f=gestures ;; *Omanotch*) f=omanotch ;; *) exit 1 ;;
esac
[[ -s "$T/state/pid-\$f" ]] && cat "$T/state/pid-\$f" || exit 1
EOF
# launchctl print gui/UID/LABEL: loaded when state/loaded-LABEL exists;
# print-disabled: state/disabled.
cat > "$T/bin/launchctl" <<EOF
#!/bin/bash
case \$1 in
  print) [[ -e "$T/state/loaded-\${2##*/}" ]] ;;
  print-disabled) cat "$T/state/disabled" 2>/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/pgrep" "$T/bin/launchctl"
export PATH="$T/bin:$PATH"
source "$R/src/lib/mac.sh"
source "$R/src/lib/app.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/notch.sh"
source "$R/src/lib/mac-setup.sh"
features_load
# The helpers' age (seconds since they started): state/age.
proc_started() { echo $(( $(date +%s) - $(cat "$T/state/age" 2>/dev/null || echo 300) )); }
notch_app_full_screen() { true; }
fails=0
expect() {   # NAME WANT GOT
  if [[ $3 == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fails=$((fails + 1)); fi
}

V=$T/vm; mkdir -p "$V"
L_B=$(omacvm_label bridge) L_G=$(omacvm_label gestures) L_N=$(omacvm_label omanotch)
reset() {   # a VM "Omarchy" with FEATURES, nothing on the Mac
  rm -rf "$V" "$T/state"/* "$HOME/Applications"/* "$HOME/Library/LaunchAgents"/* "$HOME/Library/Logs"/* "$OMA_SUPPORT" "$OMA_BRIDGE_SUPPORT"
  mkdir -p "$V"
  printf "NAME='Omarchy'\nVM_USER='me'\n" > "$V/vm.env"
  printf '%s\n' "$1" > "$V/features"
  echo "$(cat "$R/src/VERSION")" > "$V/omacvm-version"
}
put_helpers() {   # NAME...: installed, loaded and running, logs saying all is granted
  local h key app
  for h in "$@"; do
    case $h in
      bridge) key=bridge app=OmacVMBridge.app ;; gestures) key=gestures app=OmacVMGestures.app ;; omanotch) key=omanotch app=Omanotch.app ;;
    esac
    mkdir -p "$HOME/Applications/$app/Contents/MacOS"
    [[ $key == omanotch ]] && printf '/Contents/Resources/runtime/bin/OmacVM\n' > "$HOME/Applications/$app/Contents/MacOS/omanotch"
    touch "$HOME/Library/LaunchAgents/$(omacvm_label "$key").plist" "$T/state/loaded-$(omacvm_label "$key")"
    echo "$((4000 + ${#key}))" > "$T/state/pid-$key"
    [[ $key == omanotch ]] && continue
    printf '12:00:00 omacvm-%s: starting (pid %s)\n12:00:00 omacvm-%s: permissions: Accessibility granted, Input Monitoring granted\n' \
      "$key" "$((4000 + ${#key}))" "$key" > "$HOME/Library/Logs/omacvm-$key.log"
  done
}
token() {   # this Mac's token, and the VM's record of it (other: another Mac's)
  mkdir -p "$OMA_BRIDGE_SUPPORT"; printf '%064d\n' 7 > "$BRIDGE_TOKEN"
  if [[ ${1:-} == other ]]; then printf 'token %s\n' 0123456789abcdef > "$V/mac-setup"; else mac_setup_write "$V" "$BRIDGE_TOKEN"; fi
}
state() { mac_setup_state "$V"; echo "$MS_VERDICT${MS_FIX:+ $MS_FIX}${MS_WHY:+ $MS_WHY}${MS_HELPERS:+ [$MS_HELPERS]}${MS_MISSING:+ ($MS_MISSING)}"; }
ALL="bridge=on gestures=on scroll-momentum=on control-centre=on omanotch=off touch-id=off"

# ---------- which helpers ----------
reset "$ALL"; mac_setup_state "$V"
expect "needed: the Bridge and Gestures" "OmacVM Bridge|OmacVM Gestures" "$MS_NEEDED"
reset "bridge=off gestures=on scroll-momentum=on control-centre=off omanotch=off"; mac_setup_state "$V"
expect "needed: Gestures only" "OmacVM Gestures" "$MS_NEEDED"
reset "bridge=off gestures=off scroll-momentum=off control-centre=on omanotch=off"; mac_setup_state "$V"
expect "needed: the control centre needs the Bridge" "OmacVM Bridge" "$MS_NEEDED"
reset "bridge=off gestures=off scroll-momentum=on control-centre=off omanotch=off touch-id=on camera=on battery=on"
expect "scroll momentum and Touch ID without what they need, camera and battery (app VMs): nothing needed" none "$(state)"
reset "bridge=off gestures=on control-centre=off omanotch=on"
NOTCH=notch; mac_setup_state "$V"
expect "Omanotch with a notch" "OmacVM Gestures|Omanotch" "$MS_NEEDED"
NOTCH=none; mac_setup_state "$V"
expect "Omanotch: not without a notch" "OmacVM Gestures" "$MS_NEEDED"
NOTCH=notch; echo fullpanel > "$V/notch-mode"; touch "$V/fullpanel-ready"; mac_setup_state "$V"
expect "Omanotch: not for a start including the notch" "OmacVM Gestures" "$MS_NEEDED"
rm -f "$V/features"; printf "NAME='Omarchy'\nFEATURES='bridge=off gestures=off control-centre=off omanotch=off'\n" > "$V/vm.env"
expect "before the first apply: the setup's choice" none "$(state)"
# apply installs by the same map (src/cmd/apply.sh).
for l in 'mac_needs "OmacVM Bridge" || args+=(--no-bridge)' 'mac_needs "OmacVM Gestures" || args+=(--skip-gestures)' 'mac_needs Omanotch && args+=(--omanotch)' 'needs_bridge() { mac_helpers_needed; mac_needs "OmacVM Bridge"; }'; do
  grep -qF "$l" "$R/src/cmd/apply.sh" && echo "ok   apply: $l" || { echo "FAIL apply.sh no longer has: $l"; fails=$((fails + 1)); }
done
unset NOTCH

# ---------- set up or not ----------
reset "$ALL"
expect "a VM copied to a new Mac (nothing installed, no token)" "setup update-vm other-mac [OmacVM Bridge|OmacVM Gestures]" "$(state)"
echo 9.0.0 > "$V/omacvm-version"
expect "... from a newer OmacVM: the app first" "setup update-app other-mac [OmacVM Bridge|OmacVM Gestures]" "$(state)"
reset "$ALL"; token
expect "this Mac's token, the helpers removed" "setup update-vm not-installed [OmacVM Bridge|OmacVM Gestures]" "$(state)"
reset "$ALL"; put_helpers bridge gestures; token
expect "installed, running, this Mac's token" ok "$(state)"
reset "$ALL"; put_helpers bridge gestures; token other
expect "another Mac's token: set up on another Mac" "setup update-vm other-mac [OmacVM Gestures|OmacVM Bridge]" "$(state)"
reset "$ALL"; put_helpers bridge; token other
expect "another Mac's token and Gestures missing: the missing one" "setup update-vm other-mac [OmacVM Gestures]" "$(state)"
reset "$ALL"; put_helpers bridge gestures; token; rm -f "$V/mac-setup"
expect "no record (an older apply), no control centre key here: another Mac" "setup update-vm other-mac [OmacVM Gestures|OmacVM Bridge]" "$(state)"
vm_key_ensure app Omarchy > /dev/null
expect "no record, this Mac's control centre key: set up here" ok "$(state)"
reset "bridge=on gestures=on control-centre=off"; put_helpers bridge gestures; token; rm -f "$V/mac-setup"
expect "no record, control centre off: not known, no alarm" ok "$(state)"
reset "$ALL"; put_helpers bridge gestures; token; rm -f "$T/state/pid-gestures"
expect "loaded, not running (launchd starts it again): no alarm" ok "$(state)"
rm -f "$T/state/loaded-$L_G"
expect "installed, not loaded: off in Login Items" "login-items login-items [OmacVM Gestures]" "$(state)"
mv "$HOME/Applications/OmacVMGestures.app" "$HOME/Applications/UbuntuVMGestures.app"
expect "Ubuntu-named helper: Login Items state is preserved" "login-items login-items [OmacVM Gestures]" "$(state)"
mv "$HOME/Applications/UbuntuVMGestures.app" "$HOME/Applications/OmacVMGestures.app"
rm -rf "$HOME/Applications/OmacVMGestures.app"
expect "its app gone: not installed" "setup update-vm not-installed [OmacVM Gestures]" "$(state)"
reset "$ALL"; put_helpers bridge gestures; token
printf '"%s" => disabled\n' "$L_B" > "$T/state/disabled"
expect "disabled, still running: fine for now" ok "$(state)"

# ---------- permissions ----------
reset "$ALL"; put_helpers bridge gestures; token
cat > "$HOME/Library/Logs/omacvm-gestures.log" <<L
12:08:46 omacvm-gestures: starting (pid 4008)
12:08:46 omacvm-gestures: waiting for Accessibility and Input Monitoring permission
12:08:46 omacvm-gestures: permissions: Accessibility MISSING, Input Monitoring MISSING
12:08:46 omacvm-gestures: cleared what macOS kept of org.omacvm.gestures's Accessibility and Input Monitoring for an older build, so it can ask again (once per build)
L
echo 30 > "$T/state/age"
expect "Gestures waits 30 s (macOS is asking): no alarm" ok "$(state)"
echo 90 > "$T/state/age"
expect "Gestures waits 90 s: not allowed" "permission settings [OmacVM Gestures] (Accessibility, Input Monitoring)" "$(state)"
echo "12:09:19 omacvm-gestures: permissions: Accessibility granted, Input Monitoring MISSING" >> "$HOME/Library/Logs/omacvm-gestures.log"
expect "only Input Monitoring left" "permission settings [OmacVM Gestures] (Input Monitoring)" "$(state)"
printf '12:09:30 omacvm-gestures: permissions: Accessibility granted, Input Monitoring granted\n12:09:30 omacvm-gestures: permissions granted\n' >> "$HOME/Library/Logs/omacvm-gestures.log"
expect "granted: fine" ok "$(state)"
# #331: a Gestures macOS started again writes no log; the old one's lines say nothing.
printf '12:00:00 omacvm-gestures: starting (pid 1)\n12:00:00 omacvm-gestures: permissions: Accessibility MISSING, Input Monitoring MISSING\n' > "$HOME/Library/Logs/omacvm-gestures.log"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$HOME/Library/Logs/omacvm-gestures.log"
expect "a log from the process before: no verdict" ok "$(state)"
reset "$ALL"; put_helpers bridge gestures; token; echo 90 > "$T/state/age"
echo "12:00:01 omacvm-bridge: permissions: Accessibility granted, Input Monitoring MISSING" >> "$HOME/Library/Logs/omacvm-bridge.log"
expect "the Bridge without Input Monitoring (brightness keys only): no alarm" ok "$(state)"
echo "12:00:02 omacvm-bridge: permissions: Accessibility MISSING, Input Monitoring MISSING" >> "$HOME/Library/Logs/omacvm-bridge.log"
expect "the Bridge without Accessibility (media keys)" "permission settings [OmacVM Bridge] (Accessibility)" "$(state)"
rm -f "$T/state/pid-gestures" "$T/state/loaded-$L_G"; rm -rf "$HOME/Applications/OmacVMGestures.app"
expect "set up comes before permissions" "setup update-vm not-installed [OmacVM Gestures]" "$(state)"

# ---------- Omanotch ----------
reset "bridge=off gestures=off control-centre=off omanotch=on"; NOTCH=notch
expect "Omanotch not installed" "setup update-vm not-installed [Omanotch]" "$(state)"
put_helpers omanotch
expect "Omanotch running" ok "$(state)"
printf 'old\n' > "$HOME/Applications/Omanotch.app/Contents/MacOS/omanotch"
expect "Omanotch too old for app VMs" "setup update-vm too-old [Omanotch]" "$(state)"
unset NOTCH

# ---------- the test identity ----------
(
  export OMACVM_TEST_IDENTITY=1 fails=0
  source "$R/src/lib/mac.sh"; source "$R/src/lib/app.sh"
  proc_started() { echo $(( $(date +%s) - 300 )); }
  reset "$ALL omanotch=on"; NOTCH=notch
  mkdir -p "$OMA_BRIDGE_SUPPORT"; printf '%064d\n' 8 > "$BRIDGE_TOKEN"; mac_setup_write "$V" "$BRIDGE_TOKEN"
  expect "test identity: its helpers not running, no Omanotch" "setup update-vm not-running [OmacVM Bridge|OmacVM Gestures]" "$(state)"
  # Any copy of the test helpers counts (a lane's copy of the app is served by the main test app's).
  echo 5001 > "$T/state/pid-test-bridge"; echo 5002 > "$T/state/pid-test-gestures"
  expect "test identity: running" ok "$(state)"
  exit "$fails"
) || fails=$((fails + $?))

# ---------- the token's hash ----------
printf 'abc\n' > "$T/t1"; printf '  abc' > "$T/t2"
expect "token hash: whitespace does not count" "$(mac_token_hash "$T/t1")" "$(mac_token_hash "$T/t2")"
expect "token hash: sha256 of the marked token, 16 hex" "$(printf 'omacvm-bridge-token\nabc' | shasum -a 256 | cut -c1-16)" "$(mac_token_hash "$T/t1")"
: > "$T/t3"
mac_token_hash "$T/t3" > /dev/null && { echo "FAIL an empty token has a hash"; fails=$((fails + 1)); } || echo "ok   an empty token: none"
mac_setup_write "$V" "$T/t1"
expect "the record" "token $(mac_token_hash "$T/t1")" "$(cat "$V/mac-setup")"
grep -q 'mac_setup_write "$d" "$T"' "$R/src/cmd/apply.sh" && echo "ok   apply writes the record" || { echo "FAIL apply.sh does not write the record"; fails=$((fails + 1)); }

# ---------- omacvm check ----------
# Its "Mac setup" line for app VMs comes from the same function, and a helper
# not running points to Update VM there.
grep -q 'mac_setup_state "$msd"' "$R/src/cmd/check.sh" && echo "ok   check: Mac setup from mac_setup_state" || { echo "FAIL check.sh has no Mac setup line"; fails=$((fails + 1)); }
for n in Bridge Gestures; do
  grep -qF "OmacVM $n is not running (\$HELPER_FIX)" "$R/src/cmd/check.sh" && echo "ok   check: $n not running says how" ||
    { echo "FAIL check.sh: $n not running without the fix"; fails=$((fails + 1)); }
done
# The caller's features stay (check reads FV for its record lines).
FV=(caller); mac_setup_state "$V" > /dev/null
expect "the caller's FV is kept" caller "${FV[*]}"

# ---------- src/mac/install.sh --status ----------
reset "$ALL"; put_helpers bridge gestures; token other
out=$(OMACVM_MAC_NOTCH=none "$R/src/mac/install.sh" --status "$V" 2>&1); rc=$?
expect "--status: exit 0" 0 "$rc"
expect "--status: the verdict line" $'verdict\tsetup' "$(sed -n 1p <<<"$out")"
expect "--status: why" $'why\tother-mac' "$(grep '^why' <<<"$out")"
expect "--status: a line per helper" 2 "$(grep -c $'^helper\t' <<<"$out")"
expect "--status: no folder: usage" 2 "$("$R/src/mac/install.sh" --status "$T/none" > /dev/null 2>&1; echo $?)"
[[ ! -e $HOME/Library/Application\ Support/omacvm/installed ]] && echo "ok   --status installs nothing" || { echo "FAIL --status made the stamps folder"; fails=$((fails + 1)); }

# OmacVM.app reads these keys (app/app/Sources/OmacVMFeatures/MacSetup.swift).
for k in verdict fix why helpers needed missing version vm-version text; do
  grep -q "^$k"$'\t' <<<"$out" || { echo "FAIL --status: no $k line"; fails=$((fails + 1)); continue; }
  grep -qF "f[\"$k\"]" "$R/app/app/Sources/OmacVMFeatures/MacSetup.swift" && echo "ok   the app reads $k" ||
    { echo "FAIL MacSetup.swift does not read $k"; fails=$((fails + 1)); }
done
grep -qF 'p[0] == "helper"' "$R/app/app/Sources/OmacVMFeatures/MacSetup.swift" && echo "ok   the app reads the helper lines" ||
  { echo "FAIL MacSetup.swift does not read the helper lines"; fails=$((fails + 1)); }

(( fails == 0 )) && echo "mac setup: all passed" || { echo "mac setup: $fails failed"; exit 1; }
