#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
trap unmount_chroot EXIT
mount_chroot
install -d -m 700 -o 1000 -g 1000 "$ROOTFS/run/4tw-notification-test"
install -m 644 "$PROJECT/tests/notification-smoke.py" "$ROOTFS/run/4tw-notification-test/test.py"
inroot runuser -u kiosk -- env XDG_RUNTIME_DIR=/run/4tw-notification-test WLR_BACKENDS=headless WLR_RENDERER=pixman \
    dbus-run-session -- python3 /run/4tw-notification-test/test.py
