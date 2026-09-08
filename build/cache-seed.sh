#!/bin/bash

seed_optional_apt_cache() {
    [[ $# == 1 ]] || { echo 'seed_optional_apt_cache requires one destination.' >&2; return 2; }
    local destination=$1
    local old_cache=${FOURTW_OLD_APT_CACHE:-}
    mkdir -p "$destination/partial"
    # A missing optional cache is the normal fresh-clone case.
    [[ -n "$old_cache" && -d "$old_cache" ]] || return 0
    [[ "$old_cache" == /* ]] || {
        echo 'FOURTW_OLD_APT_CACHE must be an absolute native-Linux path.' >&2
        return 2
    }
    local old_resolved destination_resolved
    old_resolved=$(cd -- "$old_cache" && pwd -P)
    destination_resolved=$(cd -- "$destination" && pwd -P)
    [[ "$old_resolved" != "$destination_resolved" ]] || return 0
    # Copy reusable archives only. Never delete, move, mount or alter the source.
    rsync -a --ignore-existing --include='*.deb' --exclude='*' "$old_resolved/" "$destination_resolved/"
}
