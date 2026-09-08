#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }
IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
[[ -f "$IMAGE" && ! -L "$IMAGE" ]] || exit 1
(cd "$ARTIFACTS" && sha256sum --check 4TW-OS_RELEASE.img.sha256)
MOUNT="$WORK/verify-mount"
mkdir -p "$MOUNT"
LOOP=
VERIFY_MOUNTS=()
cleanup() {
    local i
    for ((i=${#VERIFY_MOUNTS[@]}-1; i>=0; i--)); do umount "${VERIFY_MOUNTS[i]}" || return 1; done
    VERIFY_MOUNTS=()
    if [[ -n "$LOOP" ]]; then
        [[ $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || return 1
        losetup -d "$LOOP"; LOOP=
    fi
}
trap cleanup EXIT
sgdisk --print "$IMAGE"
sgdisk --verify "$IMAGE"
# Read-only loop device protects the deliverable during inspection.
LOOP=$(losetup --find --show --read-only --partscan "$IMAGE")
[[ "$LOOP" =~ ^/dev/loop[0-9]+$ ]] || exit 1
[[ $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || exit 1
udevadm settle
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTTYPE "$LOOP"
[[ $(blkid -s TYPE -o value "${LOOP}p1") == vfat ]]
[[ $(blkid -s TYPE -o value "${LOOP}p2") == ext4 ]]
[[ $(blkid -s TYPE -o value "${LOOP}p3") == vfat ]]
[[ $(blkid -s LABEL -o value "${LOOP}p3") == 4TW-CONFIG ]]
[[ $(lsblk -n -o PARTTYPE "${LOOP}p1") == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]]
e2fsck -fn "${LOOP}p2"
fsck.vfat -vn "${LOOP}p1"
fsck.vfat -vn "${LOOP}p3"
mount -o ro,noload "${LOOP}p2" "$MOUNT"; VERIFY_MOUNTS+=("$MOUNT")
mount -o ro "${LOOP}p1" "$MOUNT/boot/efi"; VERIFY_MOUNTS+=("$MOUNT/boot/efi")
mount -o ro "${LOOP}p3" "$MOUNT/config"; VERIFY_MOUNTS+=("$MOUNT/config")
python3 "$PROJECT/tests/check-rootfs.py" "$MOUNT" "$PROJECT"
cmp "$PROJECT/config/4tw.cfg" "$MOUNT/config/4tw.cfg"
cmp "$MOUNT/usr/lib/shim/shimx64.efi.signed.latest" "$MOUNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
cmp "$MOUNT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$MOUNT/boot/efi/EFI/BOOT/grubx64.efi"
cmp "$MOUNT/usr/lib/shim/mmx64.efi" "$MOUNT/boot/efi/EFI/BOOT/mmx64.efi"
chroot "$MOUNT" dpkg --verify shim-signed grub-efi-amd64-signed
for kernel in "$MOUNT"/boot/vmlinuz-*-generic; do
    version=${kernel##*/vmlinuz-}
    chroot "$MOUNT" dpkg --verify "linux-image-$version"
done
for binary in "$MOUNT/boot/efi/EFI/BOOT/BOOTX64.EFI" "$MOUNT/boot/efi/EFI/BOOT/grubx64.efi" "$MOUNT/boot/efi/EFI/BOOT/mmx64.efi" "$MOUNT"/boot/vmlinuz-*-generic; do
    sbverify --list "$binary"
done
grub-script-check "$MOUNT/boot/grub/grub.cfg"
python3 "$PROJECT/tests/check-image.py" "$MOUNT" "$PROJECT"
for initrd in "$MOUNT"/boot/initrd.img-*-generic; do
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$MOUNT/tmp"; VERIFY_MOUNTS+=("$MOUNT/tmp")
    chroot "$MOUNT" lsinitramfs "${initrd#"$MOUNT"}" > "$ARTIFACTS/initramfs-files.txt"
    grep -F 'usr/share/plymouth/themes/4tw/4TW-OS.png' "$ARTIFACTS/initramfs-files.txt"
done
df -h "$MOUNT"
cleanup
# Test FAT32 writing on a byte-for-byte copy of the CONFIG partition only.
# This does not alter the final IMG or any real USB device.
CONFIG_COPY="$WORK/config-write-test.fat"
python3 "$PROJECT/tests/copy-config.py" "$IMAGE" "$CONFIG_COPY"
mount -o loop "$CONFIG_COPY" "$MOUNT"; VERIFY_MOUNTS+=("$MOUNT")
test -w "$MOUNT/4tw.cfg"
touch "$MOUNT/.write-test"
test -f "$MOUNT/.write-test"
sync
cleanup
echo 'PASS: CONFIG is FAT32 and accepts filesystem writes (tested on partition copy).'
(cd "$ARTIFACTS" && sha256sum --check 4TW-OS_RELEASE.img.sha256)
echo 'PASS: final IMG unchanged after all static verification.'
