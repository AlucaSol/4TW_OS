#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"

bash "$PROJECT/build/build-all.sh"
printf '\n[5/6] Compressing release with Zstandard\n'
if ! bash "$PROJECT/build/compress-release.sh" 2>&1 | tee -a "$ARTIFACTS/compress-release.log"; then
    echo '4TW-OS release compression or validation failed.' >&2
    echo "Detailed log: $ARTIFACTS/compress-release.log" >&2
    exit 1
fi
echo 'The five native Release stages completed successfully; Windows export is the final stage.'
