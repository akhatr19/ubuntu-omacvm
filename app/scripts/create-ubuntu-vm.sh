#!/bin/bash
# Install the official Ubuntu Desktop ARM64 ISO into a new VM's disk.
# VM_DIR has vm.env; stdin carries the password (or a locked test account).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "${1:?usage: create-ubuntu-vm.sh VM_DIR ISO}"
ISO=${2:-}; RESUME=${3:-}
if [[ $RESUME == --resume ]]; then
  [[ -f $VM_DIR/ubuntu-installed && ! -e $VM_DIR/ready ]] || die "no unfinished Ubuntu guest setup to resume"
else
  [[ -f $ISO && ! -e $VM_DIR/disk.img ]] || die "need an ISO and a new VM (disk.img must not exist)"
  echo 'STEP 1/4 Checking the Ubuntu image'
  log "Checking Ubuntu ISO SHA-256"
  [[ $(shasum -a 256 "$ISO" | cut -d' ' -f1) == 9242a38c47eb53a5beb153c249d4843e4366f8955e9b972663e4ab7989311e9f ]] ||
    die "Choose the official Ubuntu 26.10 Desktop ARM64 ISO"
fi
tools_ok
umask 077
T=$(mktemp -d)
cleanup() {
  qemu_running && qemu_quit
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ $RESUME != --resume ]]; then
IFS= read -r PASSWORD || true
if [[ ${OMACVM_UBUNTU_SSH_ONLY:-0} == 1 || ( ${OMACVM_UBUNTU_TEST:-0} == 1 && $NAME == "OmacVM Test-"* ) ]]; then HASH='!'
else
  [[ -n $PASSWORD ]] || die "no password on stdin"
  HASH=$(printf '%s' "$PASSWORD" | python3 "$OMACVM_SRC/prebuilt/sha512crypt.py")
fi
unset PASSWORD
printf '%s' "$HASH" | python3 "$OMACVM_SRC/ubuntu/seed.py" "$T/seed" \
  --user "$VM_USER" --hostname "$VM_HOSTNAME" --key "$VM_KEY.pub"
unset HASH
hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$T/seed.iso" "$T/seed"
tar -xf "$ISO" -C "$T" casper/vmlinuz casper/initrd
[[ -f $T/casper/vmlinuz && -f $T/casper/initrd ]] || die "not an Ubuntu live ISO"
truncate_file "$VM_DIR/disk.img" $((DISK_GB * 1024 * 1024 * 1024))
efi_vars_create
echo 'STEP 2/4 Installing Ubuntu Desktop'
log "Installing Ubuntu (see $LOG/ubuntu-install-console.log)"
OMACVM_HOST_PORTS= HOST_PORTS=
qemu_headless ubuntu-install "${QEMU_UEFI[@]}" -kernel "$T/casper/vmlinuz" -initrd "$T/casper/initrd" \
  -append "console=ttyAMA0 autoinstall ds=nocloud ---" \
  -device virtio-gpu-pci -device virtio-keyboard-pci \
  -device virtio-scsi-pci,id=scsi \
  -drive "if=none,id=iso,file=$(qe "$ISO"),format=raw,media=cdrom,readonly=on" -device scsi-cd,drive=iso \
  -drive "if=none,id=seed,file=$(qe "$T/seed.iso"),format=raw,readonly=on" -device virtio-blk-pci,drive=seed \
  -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0
qemu_wait_exit 3600 || die "Ubuntu did not finish in an hour; inspect $LOG/ubuntu-install-console.log"
! grep -q OMACVM_UBUNTU_INSTALL_FAILED "$LOG/ubuntu-install-console.log" || die "Ubuntu installation failed; inspect $LOG/ubuntu-install-console.log"
fi
echo 'STEP 3/4 Setting up graphics and desktop integration'
log "Starting the installed Ubuntu system"
qemu_headless ubuntu-system "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0
wait_ssh 300 || die "Ubuntu did not answer SSH; inspect $LOG/ubuntu-system-console.log"
touch "$VM_DIR/ubuntu-installed"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$OMACVM_SRC" -czf - . |
  vssh "mkdir -p /usr/local/share/omacvm; tar --no-same-owner -xzf - -C /usr/local/share/omacvm"
vssh "bash /usr/local/share/omacvm/ubuntu/guest/install.sh '$VM_USER' '$FEATURES' '$NAME'" |
  tee "$LOG/ubuntu-guest-install.log"
echo 'STEP 4/4 Shutting down the finished VM'
vssh "systemctl poweroff" || true
qemu_wait_exit 120 || die "Ubuntu did not shut down"
printf 'ubuntu\n' > "$VM_DIR/guest-os"
printf 'vulkan\n' > "$VM_DIR/graphics"
printf '%s\n' "$FEATURES" > "$VM_DIR/features"
sed '/^FEATURES=/d' "$VM_DIR/vm.env" > "$VM_DIR/vm.env.new"
mv "$VM_DIR/vm.env.new" "$VM_DIR/vm.env"
printf 'av1\n' > "$VM_DIR/video-decode"
cp "$OMACVM_SRC/VERSION" "$VM_DIR/omacvm-version"
touch "$VM_DIR/venus-ready" "$VM_DIR/guest-pointer" "$VM_DIR/ready"
log "Ubuntu is ready: $NAME"
