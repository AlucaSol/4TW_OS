#!/bin/bash
set -Eeuo pipefail
[[ $# == 0 ]] || { echo 'Usage: check-internet.sh' >&2; exit 2; }

for endpoint in \
    https://archive.ubuntu.com/ubuntu/dists/resolute/InRelease \
    https://packages.mozilla.org/apt/dists/mozilla/InRelease; do
    curl --fail --silent --show-error --location --max-redirs 3 \
        --connect-timeout 8 --max-time 20 --range 0-0 --output /dev/null "$endpoint"
done
echo 'Ubuntu and Mozilla package sources are reachable.'
