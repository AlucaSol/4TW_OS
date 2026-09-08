#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
# Optional build-host-only tools. They are NOT installed in the USB rootfs.
apt-get update
apt-get -y --no-install-recommends -o "Dir::Cache::archives=$CACHE" install qemu-system-x86 ovmf
