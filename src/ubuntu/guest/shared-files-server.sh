#!/bin/bash
# Private file-server VM. Only SSH is forwarded by QEMU; NFS is loopback-only.
set -euo pipefail
mountpoint -q /mnt/ubuntu-vm-personal
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nfs-kernel-server
chown 1000:1000 /mnt/ubuntu-vm-personal
chmod 755 /mnt/ubuntu-vm-personal
printf '%s\n' "$SHARE_ID" > /mnt/ubuntu-vm-personal/.ubuntu-vm-share-id
chmod 444 /mnt/ubuntu-vm-personal/.ubuntu-vm-share-id
install -d /etc/exports.d /etc/nfs.conf.d
printf '/mnt/ubuntu-vm-personal 127.0.0.1(rw,sync,fsid=0,no_subtree_check,root_squash,insecure)\n' > /etc/exports.d/ubuntu-vm.exports
printf '[nfsd]\nhost=127.0.0.1\nvers3=n\nvers4=y\nudp=n\n' > /etc/nfs.conf.d/ubuntu-vm.conf
systemctl set-default multi-user.target
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
systemctl disable --now gdm3.service 2>/dev/null || true
for service in nfs-server ubuntu-vm-files; do
  install -d "/etc/systemd/system/$service.service.d"
  printf '[Unit]\nRequires=ubuntu-vm-personal-data.service\nAfter=ubuntu-vm-personal-data.service\n' > "/etc/systemd/system/$service.service.d/data.conf"
done
systemctl daemon-reload
systemctl restart nfs-server.service
exportfs -ra
systemctl is-active --quiet nfs-server.service
