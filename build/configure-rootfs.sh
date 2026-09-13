#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }
[[ -f "$WORK/packages.ok" ]] || { echo 'Run the packages stage first.' >&2; exit 1; }
rm -f "$WORK/configured.ok"
trap unmount_chroot EXIT
mount_chroot
rsync -rt --chown=0:0 --chmod=D755,F644 "$PROJECT/rootfs-overlay/" "$ROOTFS/"
# A deleted overlay file is not removed by rsync without --delete.  Absence of
# adjtime avoids persisting either local-RTC or Linux RTC-maintenance state.
rm -f "$ROOTFS/etc/adjtime"
# Ubuntu's package default enables RTC writeback.  Remove only RTC-related
# chrony directives and retain all network/system-clock synchronization policy.
sed -E -i '/^[[:space:]]*(rtcsync|rtcfile|rtcautotrim)([[:space:]]|$)/d' "$ROOTFS/etc/chrony/chrony.conf"
while IFS= read -r -d '' chrony_config; do
    sed -E -i '/^[[:space:]]*(rtcsync|rtcfile|rtcautotrim)([[:space:]]|$)/d' "$chrony_config"
done < <(find "$ROOTFS/etc/chrony/conf.d" -type f -name '*.conf' -print0)
find "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/sbin" "$ROOTFS/usr/local/libexec" -type f -exec chmod 755 {} +
chmod 755 "$ROOTFS/etc/NetworkManager/dispatcher.d/50-4tw-timezone"
chmod 440 "$ROOTFS/etc/sudoers.d/4tw-kiosk"
install -m 644 "$PROJECT/assets/4TW-OS.png" "$ROOTFS/usr/share/plymouth/themes/4tw/4TW-OS.png"
rm -f "$ROOTFS/etc/4tw/allowed-sites.json"
python3 "$PROJECT/build/render-policy.py" "$PROJECT" "$ROOTFS"
if ! inroot id kiosk >/dev/null 2>&1; then
    inroot useradd --uid 1000 --user-group --create-home --shell /usr/local/libexec/4tw-session kiosk
fi
inroot usermod --lock --shell /usr/local/libexec/4tw-session kiosk
inroot usermod --lock root
# Browser state and FocusWriter emergency recovery are user-writable and persistent.
install -d -m 755 -o 0 -g 0 "$ROOTFS/home/kiosk" "$ROOTFS/home/kiosk/.mozilla" "$ROOTFS/etc/4tw/user-config"
install -d -m 700 -o 0 -g 0 "$ROOTFS/var/lib/4tw"
install -d -m 755 -o 0 -g 0 "$ROOTFS/writing"
install -d -m 700 -o 1000 -g 1000 "$ROOTFS/home/kiosk/.mozilla/4tw" "$ROOTFS/home/kiosk/.mozilla/firefox" \
    "$ROOTFS/home/kiosk/.local" "$ROOTFS/home/kiosk/.local/share"
ln -snf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
inroot gpasswd -a kiosk audio
inroot gpasswd -a kiosk video
inroot gpasswd -a kiosk render
inroot systemctl set-default multi-user.target
inroot systemctl enable chrony.service getty@tty1.service 4tw-configure.service \
    4tw-backlight.service 4tw-power-setup.service
inroot systemctl disable NetworkManager.service
inroot systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service \
    systemd-networkd.service systemd-networkd.socket systemd-resolved.service \
    getty@tty2.service getty@tty3.service getty@tty4.service getty@tty5.service getty@tty6.service \
    serial-getty@.service console-getty.service debug-shell.service \
    rescue.service emergency.service ctrl-alt-del.target \
    apt-daily.timer apt-daily-upgrade.timer fstrim.timer \
    dpkg-db-backup.timer e2scrub_all.timer e2scrub_reap.service motd-news.timer \
    ua-timer.timer ubuntu-advantage.service ua-reboot-cmds.service
inroot systemctl mask hwclock.service hwclock-save.service systemd-hwclock-save.service
# Ubuntu selects Plymouth through update-alternatives.
inroot update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/4tw/4tw.plymouth 200
inroot update-alternatives --set default.plymouth /usr/share/plymouth/themes/4tw/4tw.plymouth
for kernel in "$ROOTFS"/boot/vmlinuz-*-generic; do
    version=${kernel##*/vmlinuz-}
    if [[ -f "$ROOTFS/boot/initrd.img-$version" ]]; then action=-u; else action=-c; fi
    inroot update-initramfs "$action" -k "$version"
done
inroot visudo -cf /etc/sudoers
inroot python3 -m py_compile /usr/local/lib/4tw/appliance.py /usr/local/lib/4tw/rtc_clock.py \
    /usr/local/lib/4tw/timezone_provider.py /usr/local/lib/4tw/browser_session.py \
    /usr/local/bin/4tw-keyboard-brightness /usr/local/sbin/4tw-keyboard-backlight \
    /usr/local/libexec/4tw-browser /usr/local/libexec/4tw-online \
    /usr/local/libexec/4tw-return-home /usr/local/libexec/4tw-typewriter
python3 "$PROJECT/tests/test_helpers.py"
python3 "$PROJECT/tests/test_site_policy.py"
python3 "$PROJECT/tests/test_browser_session.py"
python3 "$PROJECT/tests/test_timezone.py"
python3 "$PROJECT/tests/test_rtc_clock.py"
python3 "$PROJECT/tests/test_dual_mode.py"
python3 "$PROJECT/tests/test_build_portability.py"
python3 "$PROJECT/tests/test_compress_release.py"
python3 "$PROJECT/tests/test_cleanup_native.py"
python3 "$PROJECT/tests/check-rootfs.py" "$ROOTFS" "$PROJECT"
python3 "$PROJECT/tests/check-rtc-policy.py" "$ROOTFS"
install -d -m 700 -o 1000 -g 1000 "$ROOTFS/run/4tw-sway-test"
for config in sway.conf sway-online.conf sway-offline.conf; do
    inroot runuser -u kiosk -- env XDG_RUNTIME_DIR=/run/4tw-sway-test WLR_BACKENDS=headless WLR_RENDERER=pixman \
        sway --validate --config "/etc/4tw/$config"
done
install -m 644 "$PROJECT/tests/focuswriter-smoke.py" "$ROOTFS/run/4tw-sway-test/focuswriter-smoke.py"
inroot runuser -u kiosk -- env XDG_RUNTIME_DIR=/run/4tw-sway-test WLR_BACKENDS=headless WLR_RENDERER=pixman \
    dbus-run-session -- python3 /run/4tw-sway-test/focuswriter-smoke.py | tee "$ARTIFACTS/focuswriter-smoke.json"
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-poweroff
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-backlight up
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-keyboard-backlight up
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-keyboard-backlight down
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-retry-wifi
inroot runuser -u kiosk -- sudo -n -l /usr/local/sbin/4tw-enter-offline
for request in '/usr/bin/systemctl poweroff' '/bin/sh' '/usr/local/sbin/4tw-backlight default' '/usr/local/sbin/4tw-keyboard-backlight off' '/usr/local/sbin/4tw-keyboard-backlight status' '/usr/local/sbin/4tw-keyboard-backlight up extra' '/usr/local/sbin/4tw-poweroff extra' '/usr/local/sbin/4tw-retry-wifi extra' '/usr/local/sbin/4tw-enter-offline extra'; do
    read -ra args <<< "$request"
    if inroot runuser -u kiosk -- sudo -n -l "${args[@]}"; then
        echo "Unexpected sudo permission: $request" >&2; exit 1
    fi
done
python3 "$PROJECT/tests/browser-smoke.py" "$ROOTFS" "$ARTIFACTS"
unmount_chroot
# The external archive cache is now unmounted. Clean only generated rootfs data.
mountpoint -q "$ROOTFS/var/cache/apt/archives" && exit 1
find "$ROOTFS/var/cache/apt/archives" -maxdepth 1 -type f -name '*.deb' -delete
find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} +
truncate -s 0 "$ROOTFS/etc/machine-id"
if [[ -f "$ROOTFS/var/lib/dbus/machine-id" && ! -L "$ROOTFS/var/lib/dbus/machine-id" ]]; then
    truncate -s 0 "$ROOTFS/var/lib/dbus/machine-id"
fi
rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/etc/apt/apt.conf.d/99-4tw-build-cache" "$ROOTFS/var/lib/systemd/random-seed"
# Remove only build-created account skeleton/test metadata, not the real profile.
rm -f "$ROOTFS/home/kiosk/.bashrc" "$ROOTFS/home/kiosk/.profile" "$ROOTFS/home/kiosk/.bash_logout"
find "$ROOTFS/home/kiosk/.mozilla/firefox" -type f -delete
find "$ROOTFS/home/kiosk/.mozilla/firefox" -mindepth 1 -depth -type d -empty -delete
python3 "$PROJECT/build/source-digest.py" "$PROJECT" > "$WORK/configured-source.sha256"
touch "$WORK/configured.ok"
echo 'Root filesystem configured and static helper tests passed; no disk image has been created.'
