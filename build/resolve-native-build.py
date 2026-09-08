#!/usr/bin/python3
"""Resolve the native WSL build directory without assuming a host username."""
from configparser import ConfigParser, Error as ConfigError
import os
from pathlib import Path
import pwd
import sys


class ResolutionError(RuntimeError):
    pass


def login_uid_bounds(path=Path("/etc/login.defs")):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    except OSError:
        return None
    for line in lines:
        fields = line.split()
        if len(fields) >= 2 and fields[0] in {"UID_MIN", "UID_MAX"}:
            try:
                values[fields[0]] = int(fields[1])
            except ValueError:
                return None
    if set(values) != {"UID_MIN", "UID_MAX"} or values["UID_MIN"] > values["UID_MAX"]:
        return None
    return values["UID_MIN"], values["UID_MAX"]


def wsl_default_user(path=Path("/etc/wsl.conf")):
    parser = ConfigParser(interpolation=None, strict=False)
    try:
        with path.open(encoding="utf-8") as handle:
            parser.read_file(handle)
    except (OSError, ConfigError, UnicodeError):
        return None
    section = next((name for name in parser.sections() if name.casefold() == "user"), None)
    if section is None:
        return None
    value = parser.get(section, "default", fallback="").strip()
    return value or None


def eligible_users(accounts, bounds):
    if bounds is None:
        return []
    minimum, maximum = bounds
    blocked_shells = {"/usr/sbin/nologin", "/sbin/nologin", "/bin/false"}
    return sorted(
        account.pw_name for account in accounts
        if minimum <= account.pw_uid <= maximum
        and account.pw_uid != 0
        and account.pw_shell not in blocked_shells
        and Path(account.pw_dir).is_absolute()
        and Path(account.pw_dir).parts[:2] == ("/", "home")
    )


def choose_user(environ, accounts, configured_default, bounds):
    by_name = {account.pw_name: account for account in accounts}
    explicit = environ.get("FOURTW_WSL_USER", "").strip()
    sudo_user = environ.get("SUDO_USER", "").strip()
    if explicit:
        name, source = explicit, "FOURTW_WSL_USER"
    elif sudo_user and sudo_user != "root":
        name, source = sudo_user, "SUDO_USER"
    elif configured_default and configured_default != "root":
        name, source = configured_default, "/etc/wsl.conf"
    else:
        candidates = eligible_users(accounts, bounds)
        if len(candidates) != 1:
            detail = ", ".join(candidates) if candidates else "none"
            raise ResolutionError(
                "Cannot determine one non-root WSL build user "
                f"(eligible accounts: {detail}). Set FOURTW_WSL_USER explicitly."
            )
        name, source = candidates[0], "the sole eligible login account"
    account = by_name.get(name)
    if account is None or account.pw_uid == 0:
        raise ResolutionError(f"{source} does not identify a valid non-root WSL account: {name!r}")
    return account


def native_build_directory(account, is_dir=Path.is_dir, resolve=lambda path: path.resolve(strict=True)):
    home = Path(account.pw_dir)
    try:
        resolved = resolve(home)
    except OSError:
        resolved = None
    if (not home.is_absolute() or resolved is None or resolved == Path("/")
            or resolved == Path("/root") or resolved.parts[:2] == ("/", "mnt")
            or not is_dir(home)):
        raise ResolutionError(
            f"The selected WSL account {account.pw_name!r} has an unsafe or missing home: {home}"
        )
    return resolved / "4tw-ubuntu-sway-build"


def main():
    if os.geteuid() != 0:
        raise ResolutionError("run-wsl.sh and its build stages must be invoked as WSL root.")
    accounts = pwd.getpwall()
    account = choose_user(os.environ, accounts, wsl_default_user(), login_uid_bounds())
    print(native_build_directory(account))


if __name__ == "__main__":
    try:
        main()
    except ResolutionError as error:
        print(f"4TW-OS build path error: {error}", file=sys.stderr)
        raise SystemExit(2)
