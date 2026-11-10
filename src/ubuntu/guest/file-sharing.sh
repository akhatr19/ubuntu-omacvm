# Run as root through the private guest agent. U is a validated desktop account.
set -euo pipefail
IFS= read -r PASS
[[ $U =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || exit 2
had_samba=0; command -v smbd >/dev/null 2>&1 && had_samba=1
export DEBIAN_FRONTEND=noninteractive
apt-get update </dev/null
apt-get install -y --no-install-recommends samba samba-vfs-modules rsync </dev/null
if (( ! had_samba )); then systemctl disable --now smbd nmbd >/dev/null 2>&1 || true; fi
H=$(getent passwd "$U" | cut -d: -f6)
[[ $H == /* && $H != *[$'\n\r']* ]] || exit 2
install -d -m700 /etc/ubuntu-vm /var/lib/ubuntu-vm-samba/{private,state,cache,lock} /run/ubuntu-vm-samba
cat > /etc/ubuntu-vm/smb.conf <<EOF
[global]
server role = standalone server
security = user
map to guest = Never
interfaces = lo
bind interfaces only = yes
smb ports = 1445
disable netbios = yes
server min protocol = SMB2
# SMB3 mounts authenticate but stall on file access on this macOS runtime.
# SSH supplies transport encryption/integrity for this loopback-only service.
server max protocol = SMB2_10
passdb backend = tdbsam:/var/lib/ubuntu-vm-samba/private/passdb.tdb
private dir = /var/lib/ubuntu-vm-samba/private
state directory = /var/lib/ubuntu-vm-samba/state
cache directory = /var/lib/ubuntu-vm-samba/cache
lock directory = /var/lib/ubuntu-vm-samba/lock
pid directory = /run/ubuntu-vm-samba
log file = /var/log/ubuntu-vm-samba.log
load printers = no
printing = bsd
printcap name = /dev/null
vfs objects = fruit streams_xattr
fruit:metadata = stream
fruit:resource = file
[Root]
path = /
valid users = $U
force user = root
read only = yes
browseable = yes
wide links = no
[Home]
path = $H
valid users = $U
force user = $U
read only = no
browseable = yes
wide links = no
EOF
printf '%s\n%s\n' "$PASS" "$PASS" | smbpasswd -c /etc/ubuntu-vm/smb.conf -s -a "$U" >/dev/null
unset PASS
testparm -s /etc/ubuntu-vm/smb.conf >/dev/null
cat > /etc/systemd/system/ubuntu-vm-files.service <<'EOF'
[Unit]
Description=UbuntuVM private Finder file service
After=network.target
[Service]
Type=simple
RuntimeDirectory=ubuntu-vm-samba
RuntimeDirectoryMode=0700
ExecStart=/usr/sbin/smbd --foreground --no-process-group --configfile=/etc/ubuntu-vm/smb.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ubuntu-vm-files.service >/dev/null
systemctl restart ubuntu-vm-files.service
systemctl is-active --quiet ubuntu-vm-files.service
