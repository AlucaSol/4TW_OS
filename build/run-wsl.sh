#!/bin/bash
set -Eeuo pipefail
SOURCE=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
NATIVE=/home/jonbe/4tw-ubuntu-sway-build
case "${1:-}" in
    packages) stage=prepare-packages ;;
    configure) stage=configure-rootfs ;;
    image) stage=build-img ;;
    verify) stage=verify-img ;;
    vm-tools) stage=prepare-vm-tools ;;
    boot-test) stage=boot-test ;;
    notifications) stage=test-notifications ;;
    fix-timeout) stage=fix-config-timeout ;;
    *) echo 'Usage: run-wsl.sh packages|configure|image|verify|vm-tools|boot-test' >&2; exit 2 ;;
esac
mkdir -p "$NATIVE/artifacts" "$NATIVE/assets"
rsync -rt --exclude=.work --exclude=.build-cache --exclude=artifacts --exclude=__pycache__ "$SOURCE/" "$NATIVE/"
install -m 644 "$SOURCE/../bcld/assets/4TW-OS.png" "$NATIVE/assets/4TW-OS.png"
export FOURTW_WINDOWS_SOURCE="$SOURCE"
bash "$NATIVE/build/$stage.sh" 2>&1 | tee -a "$NATIVE/artifacts/$stage.log"
mkdir -p "$SOURCE/artifacts"
# Large IMG export is a separate Windows Copy-Item operation (see README).
# Do not start concurrent 12 GiB sparse-file copies for diagnostic stages.
rsync -rt --exclude='*.img' "$NATIVE/artifacts/" "$SOURCE/artifacts/"
