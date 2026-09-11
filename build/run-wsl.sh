#!/bin/bash
set -Eeuo pipefail
SOURCE=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
[[ $EUID == 0 ]] || { echo 'Run this wrapper as WSL root.' >&2; exit 1; }
if [[ ${1:-} == host-deps ]]; then
    exec bash "$SOURCE/build/setup-host.sh" "${2:-install}"
fi
NATIVE=$(python3 "$SOURCE/build/resolve-native-build.py")
case "${1:-}" in
    all) stage=build-release ;;
    status) stage=build-all; stage_argument=--status ;;
    packages) stage=prepare-packages ;;
    configure) stage=configure-rootfs ;;
    image) stage=build-img ;;
    verify) stage=verify-img ;;
    release) stage=compress-release ;;
    release-status) stage=compress-release; stage_argument=--status ;;
    vm-tools) stage=prepare-vm-tools ;;
    boot-test) stage=boot-test ;;
    notifications) stage=test-notifications ;;
    fix-timeout) stage=fix-config-timeout ;;
    fix-wifi-retry) stage=fix-wifi-retry ;;
    *) echo 'Usage: run-wsl.sh all|status|host-deps|packages|configure|image|verify|release|release-status|vm-tools|boot-test|notifications|fix-timeout|fix-wifi-retry' >&2; exit 2 ;;
esac
source "$SOURCE/build/source-copy.sh"
sync_4tw_source "$SOURCE" "$NATIVE"
echo "Native build directory: $NATIVE"
set +e
bash "$NATIVE/build/$stage.sh" ${stage_argument:+"$stage_argument"} 2>&1 | tee -a "$NATIVE/artifacts/$stage.log"
stage_status=${PIPESTATUS[0]}
set -e
mkdir -p "$SOURCE/artifacts"
# Large IMG export is a separate Windows Copy-Item operation (see README).
# Do not start concurrent large sparse-file copies for diagnostic stages.
rsync -rt --exclude='*.img' --exclude='*.img.zst' --exclude='*.img.zst.partial' \
    "$NATIVE/artifacts/" "$SOURCE/artifacts/"
exit "$stage_status"
