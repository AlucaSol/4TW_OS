#!/bin/bash

sync_4tw_source() {
    [[ $# == 2 ]] || { echo 'sync_4tw_source requires source and destination.' >&2; return 2; }
    local source=$1
    local destination=$2
    local logo="$source/assets/4TW-OS.png"
    [[ -f "$logo" && ! -L "$logo" ]] || {
        echo "Required project logo is missing or is not a regular project-local file: $logo" >&2
        return 1
    }
    mkdir -p "$destination/artifacts" "$destination/assets"
    rsync -rt --delete --exclude=.git --exclude=.work --exclude=.build-cache --exclude=artifacts --exclude=prompts \
        --exclude=__pycache__ "$source/" "$destination/"
    install -m 644 "$logo" "$destination/assets/4TW-OS.png"
    cmp "$logo" "$destination/assets/4TW-OS.png"
}
