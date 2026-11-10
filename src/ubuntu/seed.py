#!/usr/bin/env python3
"""Write NoCloud autoinstall data; the password hash arrives on stdin."""
import argparse
import json
from pathlib import Path
import re
import sys


def config(user, hostname, password, key):
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", user):
        raise ValueError("invalid Ubuntu username")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", hostname):
        raise ValueError("invalid hostname")
    if password != "!" and not password.startswith("$6$"):
        raise ValueError("expected a SHA-512 password hash")
    if not key.startswith("ssh-ed25519 ") or "\n" in key:
        raise ValueError("expected one ed25519 public key")
    return {"autoinstall": {
        "version": 1,
        "refresh-installer": {"update": False},
        "source": {"id": "ubuntu-desktop"},
        "locale": "en_US.UTF-8",
        "keyboard": {"layout": "us"},
        "identity": {"username": user, "hostname": hostname,
                     "realname": user, "password": password},
        "storage": {"layout": {"name": "direct", "match": {"serial": "QEMU_NVMe_Ctrl_omacvm_1"}}},
        "ssh": {"install-server": True, "allow-pw": False,
                "authorized-keys": [key]},
        "user-data": {"ssh_deletekeys": False},
        "packages": ["qemu-guest-agent"],
        "error-commands": [
            "tail -n 100 /var/log/installer/subiquity-server-debug.log > /dev/ttyAMA0",
            "echo OMACVM_UBUNTU_INSTALL_FAILED > /dev/ttyAMA0",
            "systemctl poweroff",
        ],
        "late-commands": [
            "mkdir -p /mnt/omacvm",
            "mount -L cidata /mnt/omacvm",
            "install -d -m700 /target/root/.ssh",
            "install -m600 /mnt/omacvm/authorized_keys /target/root/.ssh/authorized_keys",
            "curtin in-target -- ssh-keygen -A",
            "umount /mnt/omacvm",
        ],
        "shutdown": "poweroff",
    }}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("--user", required=True)
    p.add_argument("--hostname", required=True)
    p.add_argument("--key", required=True, type=Path)
    a = p.parse_args()
    key = a.key.read_text().strip()
    data = config(a.user, a.hostname, sys.stdin.read().strip(), key)
    a.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    (a.directory / "user-data").write_text("#cloud-config\n" + json.dumps(data))
    (a.directory / "meta-data").write_text("instance-id: omacvm-ubuntu\n")
    (a.directory / "authorized_keys").write_text(key + "\n")
