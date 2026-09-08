#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }
[[ -f "$WORK/configured.ok" ]] || { echo 'Run and pass the configure stage first.' >&2; exit 1; }
[[ $(python3 "$PROJECT/build/source-digest.py" "$PROJECT") == $(cat "$WORK/configured-source.sha256") ]] || {
    echo 'Runtime source changed after validation; run configure again.' >&2; exit 1;
}
python3 "$PROJECT/tests/check-rootfs.py" "$ROOTFS" "$PROJECT"
python3 - "$ARTIFACTS/browser-smoke.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])).get('passed'), 'Firefox smoke test has not passed'
PY
IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
[[ ! -e "$IMAGE" ]] || { echo "Refusing to overwrite existing image: $IMAGE" >&2; exit 1; }
[[ $(du -sx -B1 "$ROOTFS" | cut -f1) -lt 7000000000 ]] || {
    echo 'Root filesystem too large to leave sufficient free space.' >&2; exit 1;
}
[[ -z $(findmnt -rn -o TARGET | awk -v prefix="$ROOTFS/" 'index($0,prefix)==1') ]] || {
    echo 'Root filesystem still contains build mounts.' >&2; exit 1;
}
MOUNT="$WORK/image-mount"
mkdir -p "$MOUNT"
LOOP=
IMAGE_MOUNTS=()
cleanup() {
    local i
    for ((i=${#IMAGE_MOUNTS[@]}-1; i>=0; i--)); do umount "${IMAGE_MOUNTS[i]}" || return 1; done
    IMAGE_MOUNTS=()
    if [[ -n "$LOOP" ]]; then
        [[ $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || return 1
        losetup -d "$LOOP"
        LOOP=
    fi
}
trap cleanup EXIT
truncate -s 12G "$IMAGE"
sgdisk --clear --new=1:2048:+256M --typecode=1:ef00 --change-name=1:4TW-EFI \
    --new=2:0:+11774M --typecode=2:8300 --change-name=2:4TW-ROOT \
    --new=3:0:0 --typecode=3:0700 --change-name=3:4TW-CONFIG "$IMAGE"
LOOP=$(losetup --find --show --partscan "$IMAGE")
[[ "$LOOP" =~ ^/dev/loop[0-9]+$ ]] || exit 1
[[ $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || exit 1
udevadm settle
for part in 1 2 3; do [[ -b "${LOOP}p$part" ]] || { echo 'Loop partition missing.' >&2; exit 1; }; done
mkfs.vfat -F 32 -n 4TW-EFI "${LOOP}p1"
mkfs.ext4 -F -L 4TW-ROOT -m 1 "${LOOP}p2"
mkfs.vfat -F 32 -n 4TW-CONFIG "${LOOP}p3"
ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(blkid -s UUID -o value "${LOOP}p1")
CONFIG_UUID=$(blkid -s UUID -o value "${LOOP}p3")
mount "${LOOP}p2" "$MOUNT"; IMAGE_MOUNTS+=("$MOUNT")
rsync -aHAX --numeric-ids "$ROOTFS/" "$MOUNT/"
mkdir -p "$MOUNT/boot/efi" "$MOUNT/config"
mount "${LOOP}p1" "$MOUNT/boot/efi"; IMAGE_MOUNTS+=("$MOUNT/boot/efi")
mount "${LOOP}p3" "$MOUNT/config"; IMAGE_MOUNTS+=("$MOUNT/config")
install -m 644 "$PROJECT/config/4tw.cfg" "$MOUNT/config/4tw.cfg"
install -m 644 "$PROJECT/docs/CONFIG-README.txt" "$MOUNT/config/README.txt"
touch "$MOUNT/boot/efi/4tw-esp.marker"
python3 - "$MOUNT" "$ROOT_UUID" "$ESP_UUID" "$CONFIG_UUID" <<'PY'
from pathlib import Path
import sys
root, root_uuid, esp_uuid, config_uuid = sys.argv[1:]
Path(root, 'etc/fstab').write_text(
    f'UUID={root_uuid} / ext4 defaults,noatime,errors=remount-ro 0 1\n'
    f'UUID={esp_uuid} /boot/efi vfat defaults,umask=0077,nosuid,nodev,noexec 0 2\n'
    f'UUID={config_uuid} /config vfat defaults,umask=0077,nosuid,nodev,noexec,nofail,x-systemd.device-timeout=30s 0 2\n'
    'tmpfs /tmp tmpfs defaults,nosuid,nodev,mode=1777,size=512M 0 0\n'
    'tmpfs /var/tmp tmpfs defaults,nosuid,nodev,mode=1777,size=256M 0 0\n'
)
PY
chroot "$MOUNT" /usr/local/sbin/4tw-refresh-boot
grub-script-check "$MOUNT/boot/grub/grub.cfg"
df -h "$MOUNT" "$MOUNT/boot/efi" "$MOUNT/config"
sync
cleanup
sgdisk --verify "$IMAGE"
(cd "$ARTIFACTS" && sha256sum 4TW-OS_RELEASE.img > 4TW-OS_RELEASE.img.sha256)
echo 'One complete Release disk image created. Run the verify stage against this exact file.'
