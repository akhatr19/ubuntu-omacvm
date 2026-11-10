#!/bin/bash
# Install the gestures authentication token without root writing into a home.
set -euo pipefail
U=${1:?desktop user}
H=$(getent passwd "$U" | cut -d: -f6)
source "$(dirname "$0")/../../guest/home-files.sh"
IFS= read -r token
[[ $token =~ ^[a-f0-9]{64}$ ]] || { echo 'invalid gestures token' >&2; exit 2; }
home_mkdir "$H/.config/omacvm-bridge"
home_run chmod 700 "$H/.config/omacvm-bridge"
printf '%s\n' "$token" | home_put "$H/.config/omacvm-bridge/token" 600
