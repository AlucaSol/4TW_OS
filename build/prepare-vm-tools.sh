#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }
# Optional build-host-only tools. They are NOT installed in the USB rootfs.
declare -A previously_installed=()
for package in qemu-system-x86 ovmf; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii '; then
        previously_installed[$package]=yes
    else
        previously_installed[$package]=no
    fi
done
apt-get update
apt-get -y --no-install-recommends -o "Dir::Cache::archives=$CACHE" install qemu-system-x86 ovmf
rm -f -- "$ARTIFACTS/vm-tools-host-state.txt"
{
    echo 'Optional VM tools stage completed.'
    for package in qemu-system-x86 ovmf; do
        if [[ ${previously_installed[$package]} == yes ]]; then
            printf '%s: already installed before this stage\n' "$package"
        else
            printf '%s: installed by this stage\n' "$package"
        fi
    done
    echo 'Cleanup records this information but does not purge packages from a preserved Ubuntu environment.'
} > "$ARTIFACTS/vm-tools-host-state.txt"
touch "$WORK/vm-tools.completed"
