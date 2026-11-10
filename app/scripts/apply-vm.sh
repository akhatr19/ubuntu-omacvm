#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: `omacvm apply` from the copy of
# OmacVM inside the app (the Mac side its features need, the Bridge token,
# the VM side), with the VM's features (its features file; before the first
# apply, vm.env's FEATURES).
#   apply-vm.sh VM_DIR [--no-mac | --image] [--reset-host-key]
# --image: a VM for a prebuilt image (src/prebuilt/make-image.sh app): nothing
# of this Mac, not even the Bridge token.
# --reset-host-key: the VM was rebuilt or reinstalled: forget its old SSH key.
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac | --image] [--reset-host-key]}
shift
extra=()
switches=()
while (( $# )); do
  a=$1
  case $a in
    --no-mac|--reset-host-key) extra+=("$a") ;;
    --image) extra+=(--no-mac --no-token --no-tools) ;;
    --feature) switches+=("${2:?--feature NAME=on|off}"); extra+=(--feature "$2"); shift ;;
    *) echo "apply-vm.sh: unknown option $a (--no-mac, --image, --reset-host-key)" >&2; exit 2 ;;
  esac
  shift
done
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
# OMACVM_APPLY_SSH_SECONDS: how long a VM that just started or restarted may
# take to let SSH in for good (move-vm.sh: 120); unset, one try.
rc=0; ssh_ready "${OMACVM_APPLY_SSH_SECONDS:-0}" || rc=$?
if (( rc == 2 )); then
  die "$NAME doesn't let this Mac in over SSH: it does not know this VM folder's key. Start it once in the app (it adds the key as it starts), then try again."
elif (( rc != 0 )); then
  die "$NAME does not answer over SSH (127.0.0.1:$SSH_PORT): $SSH_WHY."
fi
if [[ $(cat "$VM_DIR/guest-os" 2>/dev/null) == ubuntu ]]; then
  [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ && $VM_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid Ubuntu VM name or user"
  feats=${FEATURES:-}
  [[ ! -f $VM_DIR/features ]] || feats=$(cat "$VM_DIR/features")
  [[ -n $feats ]] || feats='gpu-compute=on battery=on camera=on'
  for switch in ${switches[@]+"${switches[@]}"}; do
    [[ $switch =~ ^(battery|camera|gestures|drag-drop)=(on|off)$ ]] || die "Ubuntu supports switching battery, camera, gestures and drag-drop here"
    feats=$(printf '%s\n' "$feats" | sed -E "s/(^| )${switch%%=*}=(on|off)( |$)/ /g")
    feats="$feats $switch"
  done
  for f in $feats; do [[ $f =~ ^[a-z0-9-]+=(on|off)$ ]] || die "invalid Ubuntu feature: $f"; done
  gesture_token=${OMACVM_UBUNTU_GESTURES_TOKEN:-$HOME/Library/Application Support/omacvm-bridge/token}
  if [[ " $feats " == *' gestures=on '* && ! -s $gesture_token ]]; then
    echo 'Set up the Mac gestures helper with app/scripts/install-ubuntu-gestures.sh first.' >&2
    exit 3
  fi
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$OMACVM_SRC" -czf - . |
    vssh "mkdir -p /usr/local/share/omacvm; tar --no-same-owner -xzf - -C /usr/local/share/omacvm"
  if [[ " $feats " == *' gestures=on '* ]]; then
    vssh "bash /usr/local/share/omacvm/ubuntu/guest/install-token.sh '$VM_USER'" < "$gesture_token"
    source "$OMACVM_SRC/lib/mac-setup.sh"
    mac_setup_write "$VM_DIR" "$gesture_token"
  fi
  vssh "bash /usr/local/share/omacvm/ubuntu/guest/install.sh '$VM_USER' '$feats' '$NAME'"
  printf '%s\n' "$feats" > "$VM_DIR/features.new"
  mv "$VM_DIR/features.new" "$VM_DIR/features"
  sed '/^FEATURES=/d' "$VM_DIR/vm.env" > "$VM_DIR/vm.env.new"
  mv "$VM_DIR/vm.env.new" "$VM_DIR/vm.env"
  cp "$OMACVM_SRC/VERSION" "$VM_DIR/omacvm-version"
  exit
fi

# A copy of src/ only: the Mac installers build next to their sources, never
# inside the app (or the source tree).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/omacvm"
cp -R "$OMACVM_SRC" "$tmp/omacvm/src"
# The app's signed Mac helpers (Contents/Helpers): installed instead of
# building them, when made from these sources (src/lib/helpers.sh).
if [[ -d $HERE/../../Helpers ]]; then
  OMACVM_HELPERS=$(cd "$HERE/../../Helpers" && pwd)
  export OMACVM_HELPERS
fi
# The app's complete omacvm (Contents/Resources/omacvm): what the Bridge runs
# for the control centre's Mac jobs when there is no checkout (apply.sh).
if [[ -x $HERE/../omacvm/omacvm ]]; then
  OMACVM_APP_CLI=$(cd "$HERE/../omacvm" && pwd)/omacvm
  export OMACVM_APP_CLI
fi
# This app's runtime: whether it has KosmicKrisp decides Graphics' Automatic
# (src/lib/graphics.sh).
for rt in "$HERE/../runtime/.build/qemu-gpu-runtime" "$HERE/../runtime"; do   # a dev tree, the app
  [[ -d $rt/lib ]] && { OMACVM_APP_RUNTIME=$(cd "$rt" && pwd); export OMACVM_APP_RUNTIME; break; }
done
args=(--vm "$NAME" --vm-type app --ip "127.0.0.1:$SSH_PORT" --user "$VM_USER" --keyboard "$KEYBOARD" --key "$KEY" --vm-key "$VM_KEY")
# The VM's features: its record (the features file) once the first apply wrote
# it, else the setup's choice (vm.env FEATURES). The fast network is the
# app's own switch (its fast-network file), which apply reads itself.
feats=${FEATURES:-}
[[ -s $VM_DIR/features ]] && feats=$(cat "$VM_DIR/features")
for f in $feats; do
  [[ $f == fast-network=* ]] || args+=(--feature "$f")
done
# A changed SSH host key: say how to forget it the app's way.
OMA_RESET_HINT="bash '$HERE/apply-vm.sh' '$VM_DIR' --reset-host-key"
export OMA_RESET_HINT
"$tmp/omacvm/src/cmd/apply.sh" "${args[@]}" ${extra[@]+"${extra[@]}"}
