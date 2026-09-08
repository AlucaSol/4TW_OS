#!/bin/bash
set -Eeuo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK="$PROJECT/.work"
ROOTFS="$WORK/rootfs"
CACHE="$PROJECT/.build-cache/apt/archives"
ARTIFACTS="$PROJECT/artifacts"
[[ $EUID == 0 ]] || { echo 'Run this build as WSL root.' >&2; exit 1; }
[[ "$PROJECT" != /mnt/* && "$PROJECT" != / ]] || {
    echo 'Build on the native WSL Linux filesystem, not /mnt/c.' >&2; exit 1;
}
mkdir -p "$WORK" "$CACHE/partial" "$ARTIFACTS"
CHROOT_MOUNTS=()
mount_chroot() {
    local name
    for name in dev proc sys run; do mkdir -p "$ROOTFS/$name"; done
    mount -t tmpfs -o mode=755,nosuid tmpfs "$ROOTFS/dev"
    CHROOT_MOUNTS+=("$ROOTFS/dev")
    for name in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9' 'tty 5 0'; do
        read -r device major minor <<< "$name"
        mknod -m 666 "$ROOTFS/dev/$device" c "$major" "$minor"
    done
    mkdir -p "$ROOTFS/dev/pts" "$ROOTFS/dev/shm"
    chmod 1777 "$ROOTFS/dev/shm"
    mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$ROOTFS/dev/pts"
    CHROOT_MOUNTS+=("$ROOTFS/dev/pts")
    ln -s pts/ptmx "$ROOTFS/dev/ptmx"
    ln -s /proc/self/fd "$ROOTFS/dev/fd"
    ln -s /proc/self/fd/0 "$ROOTFS/dev/stdin"
    ln -s /proc/self/fd/1 "$ROOTFS/dev/stdout"
    ln -s /proc/self/fd/2 "$ROOTFS/dev/stderr"
    mount -t proc proc "$ROOTFS/proc"; CHROOT_MOUNTS+=("$ROOTFS/proc")
    mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$ROOTFS/sys"
    CHROOT_MOUNTS+=("$ROOTFS/sys")
    mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$ROOTFS/run"
    CHROOT_MOUNTS+=("$ROOTFS/run")
    mkdir -p "$ROOTFS/var/cache/apt/archives"
    mount --bind "$CACHE" "$ROOTFS/var/cache/apt/archives"
    CHROOT_MOUNTS+=("$ROOTFS/var/cache/apt/archives")
}
unmount_chroot() {
    local i
    for ((i=${#CHROOT_MOUNTS[@]}-1; i>=0; i--)); do
        umount "${CHROOT_MOUNTS[i]}" || return 1
    done
    CHROOT_MOUNTS=()
}
inroot() { chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 "$@"; }
