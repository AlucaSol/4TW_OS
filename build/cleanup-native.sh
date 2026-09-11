#!/bin/bash
set -Eeuo pipefail

usage() {
    echo 'Usage: cleanup-native.sh --discover | --inspect PATH USER | --remove PATH USER' >&2
    exit 2
}

uid_bounds() {
    awk '
        $1 == "UID_MIN" {minimum=$2}
        $1 == "UID_MAX" {maximum=$2}
        END {
            if (minimum ~ /^[0-9]+$/ && maximum ~ /^[0-9]+$/ && minimum <= maximum)
                print minimum, maximum
            else
                exit 1
        }
    ' /etc/login.defs
}

account_build_path() {
    local user=$1 record name _password uid _gid home shell minimum maximum resolved_home
    [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    record=$(getent passwd "$user") || return 1
    IFS=: read -r name _password uid _gid _ home shell <<< "$record"
    [[ $name == "$user" && $uid =~ ^[0-9]+$ && $uid != 0 && -d "$home" ]] || return 1
    read -r minimum maximum < <(uid_bounds) || return 1
    (( uid >= minimum && uid <= maximum )) || return 1
    [[ $shell != /usr/sbin/nologin && $shell != /sbin/nologin && $shell != /bin/false ]] || return 1
    resolved_home=$(readlink -f -- "$home") || return 1
    [[ $resolved_home == /* && $resolved_home != / && $resolved_home != /root \
        && $resolved_home != /mnt && $resolved_home != /mnt/* ]] || return 1
    printf '%s/4tw-ubuntu-sway-build\n' "${resolved_home%/}"
}

validate_identity() {
    local build=$1 user=$2 expected
    [[ $build == /* && $build != / && $build != /root && $build != /mnt && $build != /mnt/* \
        && $build == */4tw-ubuntu-sway-build && $build != *$'\n'* ]] || {
        echo 'The requested native build path is outside the safe 4TW-OS layout.' >&2
        return 20
    }
    expected=$(account_build_path "$user") || {
        echo 'The selected WSL account cannot be validated as a normal native-home user.' >&2
        return 20
    }
    [[ $build == "$expected" ]] || {
        echo 'The requested build path does not belong to the selected WSL account.' >&2
        return 20
    }
}

validate_existing_tree() {
    local build=$1 resolved
    [[ -d "$build" && ! -L "$build" ]] || {
        echo 'The native build path is not a normal directory.' >&2
        return 20
    }
    resolved=$(readlink -f -- "$build") || return 20
    [[ $resolved == "$build" ]] || {
        echo 'The native build directory resolves somewhere unexpected.' >&2
        return 20
    }
    [[ -f "$build/build/common.sh" && ! -L "$build/build/common.sh" \
        && -f "$build/build/run-wsl.sh" && ! -L "$build/build/run-wsl.sh" ]] || {
        echo 'The candidate directory does not contain the expected 4TW-OS build sentinels.' >&2
        return 20
    }
    [[ -d "$build/.work" || -d "$build/.build-cache" || -d "$build/artifacts" ]] || {
        echo 'The candidate directory has no 4TW-OS generated-data directory.' >&2
        return 20
    }
}

project_mounts() {
    local build=$1 target
    while IFS= read -r target; do
        [[ $target == "$build" || $target == "$build/"* ]] && printf '%s\n' "$target"
    done < <(findmnt -rn --raw -o TARGET)
    return 0
}

project_loops() {
    local build=$1
    losetup --json --output NAME,BACK-FILE | python3 -c '
import json, os, sys
root = os.path.normpath(sys.argv[1])
for item in json.load(sys.stdin).get("loopdevices", []):
    name, backing = item.get("name"), item.get("back-file")
    if not isinstance(name, str) or not isinstance(backing, str):
        continue
    if backing.endswith(" (deleted)"):
        backing = backing[:-10]
    backing = os.path.normpath(backing)
    if backing.startswith(root + os.sep):
        if not name.startswith("/dev/loop") or not name[9:].isdigit():
            raise SystemExit("unsafe loop identity")
        print(name)
' "$build"
}

loop_mounts_are_private() {
    local build=$1 loop mountpoint
    while IFS= read -r loop; do
        [[ -n $loop ]] || continue
        while IFS= read -r mountpoint; do
            [[ -n $mountpoint ]] || continue
            [[ $mountpoint == "$build" || $mountpoint == "$build/"* ]] || {
                echo "A 4TW-OS loop device is mounted outside its build tree: $loop" >&2
                return 20
            }
        done < <(lsblk --json --output MOUNTPOINT "$loop" | python3 -c '
import json, sys
def visit(nodes):
    for node in nodes:
        value = node.get("mountpoint")
        if value:
            print(value)
        visit(node.get("children") or [])
visit(json.load(sys.stdin).get("blockdevices", []))
')
    done < <(project_loops "$build")
}

tree_size() {
    du -sx -B1 -- "$1" | cut -f1
}

emit_status() {
    local status=$1 build=$2 user=$3 size=$4 mounts=$5 loops=$6 vm_tools=$7
    printf 'status=%s\n' "$status"
    printf 'path=%s\n' "$build"
    printf 'selected_user=%s\n' "$user"
    printf 'size_bytes=%s\n' "$size"
    printf 'mount_count=%s\n' "$mounts"
    printf 'loop_count=%s\n' "$loops"
    printf 'vm_tools=%s\n' "$vm_tools"
}

inspect_tree() {
    local build=$1 user=$2 size mounts loops vm_tools=not-recorded
    validate_identity "$build" "$user" || return $?
    if [[ ! -e "$build" ]]; then
        emit_status absent "$build" "$user" 0 0 0 "$vm_tools"
        return 0
    fi
    validate_existing_tree "$build" || return $?
    loop_mounts_are_private "$build" || return $?
    size=$(tree_size "$build")
    mounts=$(project_mounts "$build" | sed '/^$/d' | wc -l)
    loops=$(project_loops "$build" | sed '/^$/d' | wc -l)
    [[ -f "$build/.work/vm-tools.completed" ]] && vm_tools=completed
    emit_status present "$build" "$user" "$size" "$mounts" "$loops" "$vm_tools"
}

discover_tree() {
    local name _password uid _gid home shell candidate
    local -a users=() paths=()
    while IFS=: read -r name _password uid _gid _ home shell; do
        [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]] || continue
        candidate=$(account_build_path "$name" 2>/dev/null) || continue
        if [[ -e $candidate ]]; then
            users+=("$name")
            paths+=("$candidate")
        fi
    done < <(getent passwd)
    if (( ${#paths[@]} == 0 )); then
        emit_status absent '' '' 0 0 0 not-recorded
        return 0
    fi
    if (( ${#paths[@]} != 1 )); then
        echo 'More than one possible 4TW-OS native build tree exists; cleanup will not guess.' >&2
        return 20
    fi
    inspect_tree "${paths[0]}" "${users[0]}"
}

stop_private_vm() {
    local build=$1 pid command
    [[ -e "$build/.work/vm.pid" || -e "$build/.work/vm.qmp" ]] || return 0
    [[ -f "$build/.work/vm.pid" && ! -L "$build/.work/vm.pid" ]] || {
        echo 'A VM control file exists but its project PID cannot be validated.' >&2
        return 20
    }
    read -r pid < "$build/.work/vm.pid"
    [[ $pid =~ ^[0-9]+$ ]] || return 20
    if [[ ! -d /proc/$pid ]]; then
        rm -f -- "$build/.work/vm.pid" "$build/.work/vm.qmp"
        return 0
    fi
    command=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    [[ $(readlink -f "/proc/$pid/exe") == /usr/bin/qemu-system-* \
        && $command == *'4tw-release-verification'* && $command == *"$build"* ]] || {
        echo 'A live process uses 4TW VM state but cannot be safely identified.' >&2
        return 20
    }
    kill -TERM "$pid"
    for _ in 1 2 3 4 5; do
        [[ ! -d /proc/$pid ]] && break
        sleep 1
    done
    [[ ! -d /proc/$pid ]] || {
        echo 'The project-specific test VM did not stop; cleanup stopped.' >&2
        return 20
    }
    rm -f -- "$build/.work/vm.pid" "$build/.work/vm.qmp"
}

assert_no_process_uses_tree() {
    local build=$1 process pid link target
    for process in /proc/[0-9]*; do
        pid=${process##*/}
        [[ $pid == $$ ]] && continue
        for link in "$process/cwd" "$process/root" "$process/exe" "$process"/fd/*; do
            [[ -L $link ]] || continue
            target=$(readlink -f -- "$link" 2>/dev/null) || continue
            if [[ $target == "$build" || $target == "$build/"* ]]; then
                echo "A live process still uses the 4TW-OS build tree (PID $pid); cleanup stopped." >&2
                return 20
            fi
        done
    done
}

unmount_project_tree() {
    local build=$1 target changed i
    local -a mounts=()
    mapfile -t mounts < <(project_mounts "$build")
    while (( ${#mounts[@]} > 0 )); do
        changed=0
        for ((i=0; i<${#mounts[@]}-1; i++)); do
            if (( ${#mounts[i]} < ${#mounts[i+1]} )); then
                target=${mounts[i]}; mounts[i]=${mounts[i+1]}; mounts[i+1]=$target
                changed=1
            fi
        done
        (( changed == 1 )) || break
    done
    for target in "${mounts[@]}"; do
        [[ $target == "$build" || $target == "$build/"* ]] || return 20
        umount -- "$target"
    done
    [[ -z $(project_mounts "$build") ]] || return 20
}

detach_project_loops() {
    local build=$1 loop backing
    loop_mounts_are_private "$build" || return $?
    while IFS= read -r loop; do
        [[ -n $loop && $loop =~ ^/dev/loop[0-9]+$ ]] || continue
        backing=$(losetup -n -O BACK-FILE "$loop")
        backing=${backing% (deleted)}
        [[ $backing == "$build/"* ]] || return 20
        losetup -d -- "$loop"
    done < <(project_loops "$build")
    [[ -z $(project_loops "$build") ]] || return 20
}

remove_tree() {
    local build=$1 user=$2 size vm_tools=not-recorded
    validate_identity "$build" "$user" || return $?
    if [[ ! -e "$build" ]]; then
        emit_status absent "$build" "$user" 0 0 0 "$vm_tools"
        return 0
    fi
    validate_existing_tree "$build" || return $?
    mkdir -p "$build/.work"
    exec 9>"$build/.work/build.lock"
    flock -n 9 || { echo 'A 4TW-OS build is still running; cleanup stopped.' >&2; return 20; }
    size=$(tree_size "$build")
    [[ -f "$build/.work/vm-tools.completed" ]] && vm_tools=completed
    stop_private_vm "$build" || return $?
    assert_no_process_uses_tree "$build" || return $?
    unmount_project_tree "$build" || {
        echo 'A project-specific mount could not be safely removed.' >&2; return 20;
    }
    detach_project_loops "$build" || {
        echo 'A project-specific loop device could not be safely detached.' >&2; return 20;
    }
    [[ -z $(project_mounts "$build") && -z $(project_loops "$build") ]] || return 20
    rm -rf --one-file-system -- "$build"
    [[ ! -e "$build" ]] || { echo 'The native build tree could not be completely removed.' >&2; return 20; }
    sync
    emit_status removed "$build" "$user" "$size" 0 0 "$vm_tools"
}

main() {
    [[ $EUID == 0 ]] || { echo 'Run native cleanup as WSL root.' >&2; exit 20; }
    case "${1:-}" in
        --discover)
            [[ $# == 1 ]] || usage
            discover_tree
            ;;
        --inspect)
            [[ $# == 3 ]] || usage
            inspect_tree "$2" "$3"
            ;;
        --remove)
            [[ $# == 3 ]] || usage
            remove_tree "$2" "$3"
            ;;
        *) usage ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
