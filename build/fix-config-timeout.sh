#!/bin/bash
# Targeted correction to the existing first IMG, not another image assembly.
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || exit 1
IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
[[ -f "$IMAGE" && ! -L "$IMAGE" && ! -S "$WORK/vm.qmp" ]] || {
    echo 'A regular IMG and a fully stopped VM are required.' >&2; exit 1;
}
[[ -z $(losetup -j "$IMAGE") ]] || { echo 'IMG already has a loop attachment.' >&2; exit 1; }
(cd "$ARTIFACTS" && sha256sum --check 4TW-OS_RELEASE.img.sha256)
MOUNT="$WORK/timeout-fix-mount"
mkdir -p "$MOUNT"
LOOP=$(losetup --find --show --partscan "$IMAGE")
[[ "$LOOP" =~ ^/dev/loop[0-9]+$ && $(losetup -n -O BACK-FILE "$LOOP") == "$IMAGE" ]] || exit 1
cleanup() {
    if mountpoint -q "$MOUNT"; then umount "$MOUNT" || return 1; fi
    if [[ -n "$LOOP" ]]; then losetup -d "$LOOP"; LOOP=; fi
}
trap cleanup EXIT
udevadm settle
mount "${LOOP}p2" "$MOUNT"
python3 - "$MOUNT" "$ARTIFACTS" <<'PY'
from pathlib import Path
import sys
root, artifacts = map(Path, sys.argv[1:])
assert 'MODEL=Release' in (root / 'etc/4tw-release').read_text()
path = root / 'etc/fstab'
before = path.read_text()
assert before.count('x-systemd.device-timeout=5s') == 1
(artifacts / 'fstab-before-timeout-fix.txt').write_text(before)
after = before.replace('x-systemd.device-timeout=5s', 'x-systemd.device-timeout=30s')
path.write_text(after)
(artifacts / 'fstab-final.txt').write_text(after)
PY
sync
cleanup
(cd "$ARTIFACTS" && sha256sum 4TW-OS_RELEASE.img > 4TW-OS_RELEASE.img.sha256)
echo 'Updated only the existing IMG CONFIG-device wait from 5s to 30s; no new image assembly or package downloads.'
