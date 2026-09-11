#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"

IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
CHECKSUM="$ARTIFACTS/4TW-OS_RELEASE.img.sha256"
VERIFIED_IMAGE="$WORK/verified-image.sha256"
VERIFIED_SOURCE="$WORK/verified-source.sha256"
VERIFIED_OK="$WORK/verified.ok"
CURRENT_SOURCE=$(python3 "$PROJECT/build/source-digest.py" "$PROJECT")

checksum_value() {
    [[ -f "$CHECKSUM" && ! -L "$CHECKSUM" ]] || return 1
    awk 'NR==1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$CHECKSUM"
}

image_state() {
    if [[ ! -e "$IMAGE" ]]; then
        [[ ! -e "$CHECKSUM" ]] || { echo 'Checksum exists without its IMG; move it aside before retrying.' >&2; return 20; }
        echo absent
        return 0
    fi
    [[ -f "$IMAGE" && ! -L "$IMAGE" ]] || { echo 'The output IMG path is not a regular file.' >&2; return 20; }
    local expected
    expected=$(checksum_value) || { echo 'The existing IMG has no valid adjacent checksum.' >&2; return 20; }
    if [[ -f "$VERIFIED_OK" && -f "$VERIFIED_IMAGE" && -f "$VERIFIED_SOURCE" \
            && $(<"$VERIFIED_IMAGE") == "$expected" ]]; then
        if [[ $(<"$VERIFIED_SOURCE") == "$CURRENT_SOURCE" ]]; then
            echo current-verified
        else
            echo prior-verified
        fi
        return 0
    fi
    if [[ -f "$ARTIFACTS/verify-img.log" ]] \
            && tail -n 1 "$ARTIFACTS/verify-img.log" \
                | grep -Fxq 'PASS: final IMG unchanged after all static verification.'; then
        echo legacy-verified
        return 0
    fi
    echo 'An existing IMG is not recorded as successfully verified. It was not moved or overwritten.' >&2
    return 20
}

archive_previous_image() {
    local state=$1 expected timestamp archive_name previous existing_previous
    expected=$(checksum_value)
    (cd "$ARTIFACTS" && sha256sum --check "${CHECKSUM##*/}")
    previous="$ARTIFACTS/previous"
    [[ "$previous" == "$ARTIFACTS/previous" && "$previous" != / ]] || return 1
    mkdir -p "$previous"
    existing_previous=$(find "$previous" -maxdepth 1 -type f -name '4TW-OS_RELEASE-*.img' -print -quit)
    if [[ -n "$existing_previous" && "$state" != prior-verified && "$state" != current-verified ]]; then
        echo 'A previous archived IMG already exists; refusing to discard it for an unmarked legacy image.' >&2
        return 1
    fi
    if [[ -n "$existing_previous" ]]; then
        find "$previous" -maxdepth 1 -type f \
            \( -name '4TW-OS_RELEASE-*.img' -o -name '4TW-OS_RELEASE-*.img.sha256' \
               -o -name '4TW-OS_RELEASE-*-VERIFICATION.txt' \) -delete
    fi
    timestamp=$(date -u +%Y-%m-%d-%H%M%S)
    archive_name="4TW-OS_RELEASE-$timestamp.img"
    mv -- "$IMAGE" "$previous/$archive_name"
    printf '%s  %s\n' "$expected" "$archive_name" > "$previous/$archive_name.sha256"
    rm -f -- "$CHECKSUM"
    printf 'Archived prior 4TW-OS output\nUTC timestamp: %s\nPrior state: %s\nSHA-256: %s\n' \
        "$timestamp" "$state" "$expected" > "$previous/4TW-OS_RELEASE-$timestamp-VERIFICATION.txt"
    rm -f -- "$VERIFIED_OK" "$VERIFIED_IMAGE" "$VERIFIED_SOURCE"
    echo "Archived the intact previous image as: $previous/$archive_name"
}

run_stage() {
    local number=$1 label=$2 script=$3 log=$4
    printf '\n[%s/6] %s\n' "$number" "$label"
    if ! bash "$PROJECT/build/$script" 2>&1 | tee -a "$ARTIFACTS/$log"; then
        echo "4TW-OS build stopped: [$number/6] $label failed." >&2
        echo "Detailed log: $ARTIFACTS/$log" >&2
        return 1
    fi
}

case "${1:-}" in
    --status)
        state=$(image_state) || exit $?
        [[ $state == current-verified ]] && exit 0
        exit 10
        ;;
    --rebuild|'') ;;
    *) echo 'Usage: build-all.sh [--status|--rebuild]' >&2; exit 2 ;;
esac

state=$(image_state) || exit $?
if [[ $state == current-verified && ${1:-} != --rebuild ]]; then
    echo 'The current runtime source already has a verified Release IMG; reusing it.'
    exit 0
fi

run_stage 1 'Preparing Ubuntu packages (the first build is the slowest)' prepare-packages.sh prepare-packages.log
run_stage 2 'Configuring and testing 4TW-OS' configure-rootfs.sh configure-rootfs.log
if [[ $state != absent ]]; then
    archive_previous_image "$state"
fi
run_stage 3 'Creating the writable Release USB image' build-img.sh build-img.log
run_stage 4 'Verifying the exact Release image' verify-img.sh verify-img.log
echo 'All four core 4TW-OS image stages completed successfully.'
