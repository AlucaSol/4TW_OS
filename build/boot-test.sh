#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
python3 "$PROJECT/tests/boot-vm.py" "$PROJECT"
