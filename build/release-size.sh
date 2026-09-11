#!/bin/bash

GITHUB_RELEASE_LIMIT_BYTES=2147483648

release_size_gib() {
    awk -v bytes="$1" 'BEGIN {printf "%.2f", bytes / 1073741824}'
}

release_headroom_mib() {
    awk -v bytes="$1" -v limit="$GITHUB_RELEASE_LIMIT_BYTES" \
        'BEGIN {printf "%.0f", (limit - bytes) / 1048576}'
}

github_release_size_report() {
    local bytes=${1:-}
    [[ $bytes =~ ^[0-9]+$ ]] || { echo 'Compressed release size is invalid.' >&2; return 2; }
    printf 'Compressed release: %s GiB (%s bytes)\n' "$(release_size_gib "$bytes")" "$bytes"
    if (( bytes < GITHUB_RELEASE_LIMIT_BYTES )); then
        echo 'GitHub Release size check: PASS'
        printf 'Headroom: approximately %s MiB\n' "$(release_headroom_mib "$bytes")"
        return 0
    fi
    echo 'GitHub Release size check: FAIL'
    echo 'The compressed artifact is not suitable for upload under the 2 GiB per-file limit.'
    return 3
}
