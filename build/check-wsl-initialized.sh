#!/bin/bash
set -Eeuo pipefail
[[ $# == 0 ]] || { echo 'Usage: check-wsl-initialized.sh' >&2; exit 2; }

read -r uid_min uid_max < <(
    awk '$1=="UID_MIN" {minimum=$2} $1=="UID_MAX" {maximum=$2}
         END {if (minimum && maximum) print minimum, maximum}' /etc/login.defs
)
[[ $uid_min =~ ^[0-9]+$ && $uid_max =~ ^[0-9]+$ ]] || exit 2

eligible=0
while IFS=: read -r _ _ uid _ _ home shell; do
    if (( uid >= uid_min && uid <= uid_max && uid != 0 )) \
            && [[ $home == /home/* ]] \
            && [[ $shell != /usr/sbin/nologin && $shell != /sbin/nologin && $shell != /bin/false ]]; then
        ((eligible+=1))
    fi
done < /etc/passwd

# Exit 10 is a stable launcher signal meaning standard Ubuntu user setup is
# still required.  The authoritative account choice remains in the existing
# resolve-native-build.py helper.
(( eligible > 0 )) || exit 10
echo 'Ubuntu has at least one eligible non-root build account.'
