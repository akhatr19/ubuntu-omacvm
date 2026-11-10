#!/bin/bash
# First boot of an ordinary checkpoint fork. Called through the private guest agent.
set -euo pipefail
U=${1:?user}; TOKEN=${2:?identity}; NAME_B64=${3:?VM name}; KEY=${4:?public key}
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ && $TOKEN =~ ^[0-9a-f]{32}$ && $KEY == 'ssh-ed25519 '* && $KEY != *[$'\n\r']* ]] || exit 2
STAMP=/var/lib/ubuntu-vm/fork-identity
BOOT=$(cat /proc/sys/kernel/random/boot_id)
if [[ -f $STAMP ]]; then
  read -r previous previous_boot < "$STAMP"
  if [[ $previous == "$TOKEN" ]]; then
    if [[ $previous_boot != "$BOOT" ]]; then echo already
    else systemd-run --quiet --on-active=2s /usr/bin/systemctl reboot; fi
    exit 0
  fi
fi
install -d -m700 /var/lib/ubuntu-vm /root/.ssh
printf '%s\n' "$KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
H=$(getent passwd "$U" | cut -d: -f6)
runuser -u "$U" -- env HOME="$H" bash -c 'set -e; umask 077; mkdir -p "$HOME/.ssh"; printf "%s\n" "$1" > "$HOME/.ssh/authorized_keys"' bash "$KEY"
rm -f "/etc/ssh/ubuntu-vm/$U" /etc/ssh/ssh_host_*
ssh-keygen -A
systemd-id128 new > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
hostnamectl set-hostname "ubuntu-${TOKEN:0:12}"
if [[ -f /etc/omacvm/env ]]; then sed -i "s|^OMACVM_VM_NAME_B64=.*|OMACVM_VM_NAME_B64=$NAME_B64|" /etc/omacvm/env; fi
printf '%s %s\n' "$TOKEN" "$BOOT" > "$STAMP"
sync
systemd-run --quiet --on-active=2s /usr/bin/systemctl reboot
