#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
source "$PROJECT/build/release-size.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }

IMAGE="$ARTIFACTS/4TW-OS_RELEASE.img"
IMAGE_CHECKSUM="$ARTIFACTS/4TW-OS_RELEASE.img.sha256"
RELEASE="$ARTIFACTS/4TW-OS_RELEASE.img.zst"
RELEASE_PARTIAL="$ARTIFACTS/4TW-OS_RELEASE.img.zst.partial"
RELEASE_CHECKSUM="$ARTIFACTS/4TW-OS_RELEASE.img.zst.sha256"
RELEASE_SOURCE="$ARTIFACTS/4TW-OS_RELEASE.img.zst.source.sha256"
RELEASE_REPORT="$ARTIFACTS/RELEASE.txt"
RELEASE_OK="$WORK/release.ok"
VERIFIED_OK="$WORK/verified.ok"
VERIFIED_IMAGE="$WORK/verified-image.sha256"

checksum_value() {
    local path=$1 expected_name=$2
    [[ -f "$path" && ! -L "$path" ]] || return 1
    awk -v name="$expected_name" \
        'NR == 1 && NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && $2 == name {print $1}' "$path"
}

verified_raw_hash() {
    [[ -f "$IMAGE" && ! -L "$IMAGE" ]] || {
        echo 'The verified raw Release IMG is missing or unsafe.' >&2; return 1;
    }
    [[ -f "$VERIFIED_OK" && ! -L "$VERIFIED_OK" && -f "$VERIFIED_IMAGE" && ! -L "$VERIFIED_IMAGE" ]] || {
        echo 'The raw IMG has no successful verification marker; release compression was refused.' >&2; return 1;
    }
    local expected recorded
    expected=$(checksum_value "$IMAGE_CHECKSUM" '4TW-OS_RELEASE.img') || {
        echo 'The raw IMG checksum file is missing or malformed.' >&2; return 1;
    }
    recorded=$(<"$VERIFIED_IMAGE")
    [[ $recorded == "$expected" ]] || {
        echo 'The raw IMG checksum is not the checksum recorded by verify-img.' >&2; return 1;
    }
    (cd "$ARTIFACTS" && sha256sum --check '4TW-OS_RELEASE.img.sha256') >&2 || {
        echo 'The raw IMG bytes no longer match the verified checksum.' >&2; return 1;
    }
    printf '%s\n' "$expected"
}

release_is_current() {
    local raw_hash=$1 recorded_source
    [[ -f "$RELEASE" && ! -L "$RELEASE" && -f "$RELEASE_CHECKSUM" && ! -L "$RELEASE_CHECKSUM" \
        && -f "$RELEASE_SOURCE" && ! -L "$RELEASE_SOURCE" ]] || return 1
    recorded_source=$(checksum_value "$RELEASE_SOURCE" '4TW-OS_RELEASE.img') || return 1
    [[ $recorded_source == "$raw_hash" ]] || return 1
    (cd "$ARTIFACTS" && sha256sum --check '4TW-OS_RELEASE.img.zst.sha256') >/dev/null 2>&1 || return 1
    zstd --test --quiet "$RELEASE" >/dev/null 2>&1 || return 1
}

write_report() {
    local raw_hash=$1 release_hash=$2 size=$3 size_result=0
    github_release_size_report "$size" || size_result=$?
    rm -f -- "$RELEASE_REPORT"
    {
        echo '4TW-OS compressed Release verification'
        printf 'Verified UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'Raw IMG SHA-256: %s\n' "$raw_hash"
        printf 'Compressed SHA-256: %s\n' "$release_hash"
        printf 'Compressed bytes: %s\n' "$size"
        if (( size_result == 0 )); then
            echo 'Zstandard integrity: PASS'
            echo 'GitHub Release size check: PASS'
        else
            echo 'Zstandard integrity: PASS'
            echo 'GitHub Release size check: FAIL'
        fi
    } > "$RELEASE_REPORT"
    return "$size_result"
}

case "${1:-}" in
    ''|--status) ;;
    *) echo 'Usage: compress-release.sh [--status]' >&2; exit 2 ;;
esac

command -v zstd >/dev/null 2>&1 || {
    echo 'Zstandard is not installed on the WSL build host. Rerun BUILD-4TW-OS.cmd.' >&2
    exit 20
}
raw_hash=$(verified_raw_hash) || exit 20

if release_is_current "$raw_hash"; then
    release_hash=$(checksum_value "$RELEASE_CHECKSUM" '4TW-OS_RELEASE.img.zst')
    release_size=$(stat -c %s "$RELEASE")
    if write_report "$raw_hash" "$release_hash" "$release_size"; then
        touch "$RELEASE_OK"
        [[ ${1:-} == --status ]] || echo 'The existing compressed release matches the verified raw IMG; reusing it.'
        exit 0
    fi
    rm -f -- "$RELEASE_OK"
    exit 3
fi

rm -f -- "$RELEASE_OK"
if [[ ${1:-} == --status ]]; then
    exit 10
fi

if [[ -e "$RELEASE_PARTIAL" && ! -f "$RELEASE_PARTIAL" ]]; then
    echo 'Release compression failed: the temporary output path is not a regular file.' >&2
    exit 1
fi
rm -f -- "$RELEASE_PARTIAL"
echo 'Compressing 4TW-OS for distribution...'
echo 'This may take several minutes.'
if ! zstd -T0 -10 --force "$IMAGE" -o "$RELEASE_PARTIAL"; then
    echo 'Release compression failed. The verified raw IMG, logs and package cache were preserved.' >&2
    exit 1
fi
if ! zstd --test --quiet "$RELEASE_PARTIAL"; then
    echo 'Release compression failed: Zstandard integrity testing rejected the new stream.' >&2
    exit 1
fi
# zstd preserves the raw image's timestamp by default. Mark the distribution
# artifact with its actual creation time so Windows does not make a newly
# compressed release look like an older build.
touch "$RELEASE_PARTIAL"
release_hash=$(sha256sum "$RELEASE_PARTIAL" | awk 'NR == 1 {print $1}')
[[ $release_hash =~ ^[0-9a-f]{64}$ ]] || { echo 'Could not hash the compressed release.' >&2; exit 1; }
mv -f -- "$RELEASE_PARTIAL" "$RELEASE"
rm -f -- "$RELEASE_CHECKSUM.partial" "$RELEASE_SOURCE.partial"
printf '%s  4TW-OS_RELEASE.img.zst\n' "$release_hash" > "$RELEASE_CHECKSUM.partial"
printf '%s  4TW-OS_RELEASE.img\n' "$raw_hash" > "$RELEASE_SOURCE.partial"
mv -f -- "$RELEASE_CHECKSUM.partial" "$RELEASE_CHECKSUM"
mv -f -- "$RELEASE_SOURCE.partial" "$RELEASE_SOURCE"
(cd "$ARTIFACTS" && sha256sum --check '4TW-OS_RELEASE.img.zst.sha256')
zstd --test --quiet "$RELEASE"
release_size=$(stat -c %s "$RELEASE")
if write_report "$raw_hash" "$release_hash" "$release_size"; then
    touch "$RELEASE_OK"
    echo 'Zstandard integrity test: PASS'
    printf 'Compressed SHA-256: %s\n' "$release_hash"
    exit 0
fi
echo 'The compressed stream is valid, but release export was stopped because it is not below 2 GiB.' >&2
exit 3
