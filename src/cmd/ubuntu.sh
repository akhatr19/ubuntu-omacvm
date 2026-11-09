#!/bin/bash
# Ubuntu Desktop in OmacVM's existing runtime, without the Omarchy installer.
#   omacvm ubuntu build --iso PATH --vm-name NAME --user USER
#                        [--cpus N] [--memory-gb N] [--disk-gb N]
#   omacvm ubuntu check --vm-name NAME
#   omacvm ubuntu resume --vm-name NAME   retry an unfinished guest setup
# The ISO must be the official Ubuntu 26.10 Desktop ARM64 image. Build asks
# for your Ubuntu password in a terminal, or reads OMACVM_PASSWORD.
# This source-tree command requires app/runtime/.build (see docs/ubuntu.md).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/app/scripts
[[ -d $S ]] || S=$R/../scripts
ACTION=${1:---help}; (( $# == 0 )) || shift
NAME=Ubuntu; U=ubuntu; ISO=""; CPUS=4; MEM_GB=8; DISK_GB=64; SSH_PORT=52224; AUTH=password; PROFILE=desktop
usage() { echo "omacvm ubuntu: $*" >&2; exit 2; }
while (( $# )); do
  [[ $# -ge 2 ]] || usage "$1 needs a value"
  case $1 in
    --iso) ISO=$2 ;;
    --auth) AUTH=$2 ;;
    --profile) PROFILE=$2 ;;
    --vm-name) NAME=$2 ;;
    --user) U=$2 ;;
    --cpus) CPUS=$2 ;;
    --memory-gb) MEM_GB=$2 ;;
    --disk-gb) DISK_GB=$2 ;;
    --ssh-port) SSH_PORT=$2 ;;
    *) usage "unknown option $1" ;;
  esac
  shift 2
done
case $ACTION in
  --help|-h) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
  build|check|resume) ;;
  *) usage "build, resume or check (see --help)" ;;
esac
[[ $AUTH == password || $AUTH == ssh-only ]] || usage "--auth password|ssh-only"
[[ $PROFILE == desktop || $PROFILE == developer ]] || usage "--profile desktop|developer"
[[ $AUTH != ssh-only ]] || export OMACVM_UBUNTU_SSH_ONLY=1
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,63}$ && $NAME != *..* ]] || usage "invalid VM name"
[[ $U =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || usage "invalid Ubuntu username"
for n in "$CPUS" "$MEM_GB" "$DISK_GB"; do [[ $n =~ ^[1-9][0-9]{0,3}$ ]] || usage "resources must be positive integers"; done
[[ $SSH_PORT =~ ^[1-9][0-9]{3,4}$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || usage "invalid SSH port"
(( CPUS <= $(sysctl -n hw.ncpu) && MEM_GB >= 6 && MEM_GB * 1073741824 <= $(sysctl -n hw.memsize) && DISK_GB >= 32 )) ||
  usage "need 6+ GB RAM, 32+ GB disk, and CPU/RAM within this Mac's capacity"
VM_ROOT=${OMACVM_VMS_ROOT:-$HOME/UbuntuVMs}
VM_DIR=$VM_ROOT/$NAME
if [[ $ACTION == resume ]]; then
  exec "$S/create-ubuntu-vm.sh" "$VM_DIR" "" --resume
fi
if [[ $ACTION == check ]]; then
  source "$S/vm-common.sh"
  vm_load "$VM_DIR"
  [[ $(cat "$VM_DIR/guest-os" 2>/dev/null) == ubuntu ]] || usage "not an Ubuntu VM"
  vssh "bash /usr/local/share/omacvm/ubuntu/guest/check.sh"
  exit
fi
[[ -f $ISO ]] || usage "--iso needs an Ubuntu Desktop ARM64 ISO"
ISO=$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")
want=9242a38c47eb53a5beb153c249d4843e4366f8955e9b972663e4ab7989311e9f
echo "Checking Ubuntu ISO SHA-256"
[[ $(shasum -a 256 "$ISO" | cut -d' ' -f1) == "$want" ]] || usage "ISO is not the pinned Ubuntu 26.10 Desktop ARM64 release"
[[ ! -e $VM_DIR ]] || usage "$VM_DIR already exists; nothing changed"
! lsof -nP -iTCP:"$SSH_PORT" -sTCP:LISTEN >/dev/null 2>&1 || usage "SSH port $SSH_PORT is already in use"
PASSWORD=${OMACVM_PASSWORD:-}; unset OMACVM_PASSWORD
if [[ $AUTH != ssh-only && ( ${OMACVM_UBUNTU_TEST:-0} != 1 || $NAME != "OmacVM Test-"* ) ]]; then
  if [[ -z $PASSWORD && -t 0 ]]; then read -r -s -p "Ubuntu password: " PASSWORD; echo; fi
  [[ -n $PASSWORD ]] || { echo "Set your Ubuntu password in OMACVM_PASSWORD, or run in a terminal" >&2; exit 3; }
fi
umask 077
mkdir -p "$VM_DIR"
{
  printf "NAME='%s'\nCPUS=%s\nMEM_MB=%s\nDISK_GB=%s\nSSH_PORT=%s\n" "$NAME" "$CPUS" "$((MEM_GB * 1024))" "$DISK_GB" "$SSH_PORT"
  printf 'VM_USER=%s\nVM_HOSTNAME=ubuntu\nKEYBOARD=us\nFEATURES=' "$U"
  while IFS=$'\t' read -r f _; do
    [[ -n $f && $f != \#* ]] || continue
    if [[ $f == gpu-compute || ( $PROFILE == desktop && ( $f == battery || $f == camera || $f == drag-drop ) ) ]]; then printf '%s=on ' "$f"; else printf '%s=off ' "$f"; fi
  done < "$R/src/features.tsv"
  echo
} > "$VM_DIR/vm.env"
printf 'ubuntu\n' > "$VM_DIR/guest-os"
# FEATURES is a single shell value, as VMConfig.load expects.
sed -i '' "s/^FEATURES=\(.*\)$/FEATURES='\1'/" "$VM_DIR/vm.env"
printf '%s\n' "$PASSWORD" | "$S/create-ubuntu-vm.sh" "$VM_DIR" "$ISO"
