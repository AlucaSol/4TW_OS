#!/bin/bash
set -Eeuo pipefail

packages=(
    ca-certificates coreutils curl debootstrap dosfstools e2fsprogs gdisk gnupg
    grub-common mount python3 rsync sbsigntool udev util-linux zstd
)
commands=(
    awk blkid chroot curl debootstrap e2fsck findmnt flock fsck.vfat gpg
    grub-script-check losetup mkfs.ext4 mkfs.vfat mount python3 rsync sbverify
    setpriv sgdisk sha256sum udevadm zstd
)

check_dependencies() {
    local command
    for command in "${commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
}

case "${1:-install}" in
    --check)
        check_dependencies
        ;;
    install)
        [[ $EUID == 0 ]] || { echo 'Build-host package setup must run as WSL root.' >&2; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y --no-install-recommends install "${packages[@]}"
        check_dependencies || { echo 'A required 4TW-OS build command is still unavailable.' >&2; exit 1; }
        echo '4TW-OS build-host dependencies are ready.'
        ;;
    *)
        echo 'Usage: setup-host.sh [--check]' >&2
        exit 2
        ;;
esac
