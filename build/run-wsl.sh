#!/bin/bash
set -Eeuo pipefail
SOURCE=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
[[ $EUID == 0 ]] || { echo 'Run this wrapper as WSL root.' >&2; exit 1; }
NATIVE=$(python3 "$SOURCE/build/resolve-native-build.py")
case "${1:-}" in
    packages) stage=prepare-packages ;;
    configure) stage=configure-rootfs ;;
    image) stage=build-img ;;
    verify) stage=verify-img ;;
    vm-tools) stage=prepare-vm-tools ;;
    boot-test) stage=boot-test ;;
    notifications) stage=test-notifications ;;
    fix-timeout) stage=fix-config-timeout ;;
    fix-wifi-retry) stage=fix-wifi-retry ;;
    *) echo 'Usage: run-wsl.sh packages|configure|image|verify|vm-tools|boot-test|notifications|fix-timeout|fix-wifi-retry' >&2; exit 2 ;;
esac
source "$SOURCE/build/source-copy.sh"
sync_4tw_source "$SOURCE" "$NATIVE"
echo "Native build directory: $NATIVE"
bash "$NATIVE/build/$stage.sh" 2>&1 | tee -a "$NATIVE/artifacts/$stage.log"
mkdir -p "$SOURCE/artifacts"
# Large IMG export is a separate Windows Copy-Item operation (see README).
# Do not start concurrent large sparse-file copies for diagnostic stages.
rsync -rt --exclude='*.img' "$NATIVE/artifacts/" "$SOURCE/artifacts/"
