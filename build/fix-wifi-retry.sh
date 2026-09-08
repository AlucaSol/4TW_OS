#!/bin/bash
# Replace only the validated online launcher in an already-built IMG.
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }

[[ -f "$WORK/configured.ok" ]] || {
    echo 'Run and pass the configure stage first.' >&2; exit 1;
}
[[ $(python3 "$PROJECT/build/source-digest.py" "$PROJECT") == $(cat "$WORK/configured-source.sha256") ]] || {
    echo 'Runtime source changed after validation; run configure again.' >&2; exit 1;
}

IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
[[ -f "$IMAGE" && ! -L "$IMAGE" && ! -S "$WORK/vm.qmp" ]] || {
    echo 'A regular IMG and a fully stopped VM are required.' >&2; exit 1;
}
[[ -z $(losetup -j "$IMAGE") ]] || {
    echo 'IMG already has a loop attachment.' >&2; exit 1;
}
(cd "$ARTIFACTS" && sha256sum --check 4TW-OS_RELEASE.img.sha256)

MOUNT="$WORK/wifi-retry-fix-mount"
mkdir -p "$MOUNT"
LOOP=
cleanup() {
    if mountpoint -q "$MOUNT"; then umount "$MOUNT" || return 1; fi
    if [[ -n "$LOOP" ]]; then
        [[ $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || return 1
        losetup -d "$LOOP"
        LOOP=
    fi
}
trap cleanup EXIT

LOOP=$(losetup --find --show --partscan "$IMAGE")
[[ "$LOOP" =~ ^/dev/loop[0-9]+$ && $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || exit 1
udevadm settle
mount "${LOOP}p2" "$MOUNT"

TARGET="$MOUNT/usr/local/libexec/4tw-online"
SOURCE="$PROJECT/rootfs-overlay/usr/local/libexec/4tw-online"
[[ -f "$MOUNT/etc/4tw-release" ]] || exit 1
grep -Fxq 'MODEL=Release' "$MOUNT/etc/4tw-release"
[[ -f "$TARGET" && ! -L "$TARGET" && -f "$SOURCE" && ! -L "$SOURCE" ]] || exit 1
install -m 0755 -o root -g root "$SOURCE" "$TARGET"
cmp "$SOURCE" "$TARGET"
python3 "$PROJECT/tests/check-rootfs.py" "$MOUNT" "$PROJECT"

sync
cleanup
(cd "$ARTIFACTS" && sha256sum 4TW-OS_RELEASE.img > 4TW-OS_RELEASE.img.sha256)
echo 'Updated only 4tw-online in the existing IMG; no new image assembly or package downloads.'
