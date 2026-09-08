#!/bin/bash
set -Eeuo pipefail
source "$(dirname -- "$0")/common.sh"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another build is running.' >&2; exit 1; }
rm -f "$WORK/configured.ok"
trap unmount_chroot EXIT
OLD_CACHE=/home/jonbe/bcld-4thewords-build/.build-cache/apt/archives
if [[ -d "$OLD_CACHE" ]]; then
    # Copy, never alter or mount the old BCLD cache writable.
    rsync -a --ignore-existing --include='*.deb' --exclude='*' "$OLD_CACHE/" "$CACHE/"
fi
echo "Seeded cache: $(find "$CACHE" -maxdepth 1 -name '*.deb' | wc -l) packages"
if [[ ! -f "$WORK/bootstrap.ok" ]]; then
    [[ ! -e "$ROOTFS/etc/os-release" ]] || {
        echo 'An incomplete bootstrap exists; inspect it before retrying.' >&2; exit 1;
    }
    debootstrap --arch=amd64 --variant=minbase --cache-dir="$CACHE" \
        --include=ca-certificates,ubuntu-keyring,gnupg \
        resolute "$ROOTFS" https://archive.ubuntu.com/ubuntu
    touch "$WORK/bootstrap.ok"
fi
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
mount_chroot
install -m 755 "$PROJECT/build/policy-rc.d" "$ROOTFS/usr/sbin/policy-rc.d"
install -m 644 "$PROJECT/build/ubuntu.sources" "$ROOTFS/etc/apt/sources.list.d/ubuntu.sources"
if [[ -f "$ROOTFS/etc/apt/sources.list" ]]; then
    # Replace only debootstrap's generated list, avoiding duplicate entries.
    truncate -s 0 "$ROOTFS/etc/apt/sources.list"
fi
install -m 644 "$PROJECT/build/apt-cache.conf" "$ROOTFS/etc/apt/apt.conf.d/99-4tw-build-cache"
mkdir -p "$ROOTFS/etc/apt/keyrings"
curl --fail --location --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
    -o "$WORK/mozilla-key.asc"
fingerprint=$(gpg --batch --show-keys --with-colons "$WORK/mozilla-key.asc" | awk -F: '$1=="fpr" {print $10; exit}')
[[ "$fingerprint" == 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3 ]] || {
    echo 'Mozilla signing key fingerprint mismatch.' >&2; exit 1;
}
install -m 644 "$WORK/mozilla-key.asc" "$ROOTFS/etc/apt/keyrings/packages.mozilla.org.asc"
install -m 644 "$PROJECT/build/mozilla.sources" "$ROOTFS/etc/apt/sources.list.d/mozilla.sources"
install -m 644 "$PROJECT/build/mozilla.pref" "$ROOTFS/etc/apt/preferences.d/mozilla"
inroot apt-get update
inroot apt-get -y --no-install-recommends dist-upgrade
mapfile -t packages < <(sed '/^#/d; /^$/d' "$PROJECT/config/packages.txt")
inroot apt-get -y --no-install-recommends install "${packages[@]}"
inroot dpkg-query -W '-f=${Package}\t${Version}\t${Architecture}\n' > "$ARTIFACTS/packages.tsv"
inroot apt-cache policy firefox shim-signed grub-efi-amd64-signed linux-generic > "$ARTIFACTS/package-origins.txt"
unmount_chroot
touch "$WORK/packages.ok"
echo 'Package preparation complete; no disk image has been created.'
