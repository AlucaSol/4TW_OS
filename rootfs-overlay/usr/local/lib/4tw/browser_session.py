"""Fixed-purpose Firefox kiosk supervision and Return Home signalling."""
import os
from pathlib import Path
import signal
import subprocess
import time

from appliance import read_validated_start_url

PROFILE = Path("/home/kiosk/.mozilla/4tw")
SUPERVISOR_PID = Path("/run/user/1000/4tw-browser.pid")
MODE_PATH = Path("/run/4tw/mode")
SUPERVISOR_SCRIPT = "/usr/local/libexec/4tw-browser"
SESSION_FILES = ("sessionstore.jsonlz4", "sessionCheckpoints.json")
SESSION_BACKUP_FILES = {
    "recovery.jsonlz4", "recovery.baklz4", "previous.jsonlz4",
}


def firefox_command(start_url):
    """The one canonical kiosk launch command, with one positional URL."""
    return [
        "/usr/bin/firefox", "--kiosk", "--no-remote", "--profile",
        str(PROFILE), start_url,
    ]


def clear_session_restore(profile=PROFILE):
    """Remove tab/window recovery metadata without touching site or login data."""
    removed = []
    for name in SESSION_FILES:
        candidate = profile / name
        try:
            if candidate.is_file() or candidate.is_symlink():
                candidate.unlink()
                removed.append(candidate)
        except OSError:
            pass
    backups = profile / "sessionstore-backups"
    try:
        if backups.is_symlink() or not backups.is_dir():
            return removed
        candidates = list(backups.iterdir())
    except OSError:
        return removed
    for candidate in candidates:
        if candidate.name not in SESSION_BACKUP_FILES and not candidate.name.startswith("upgrade.jsonlz4-"):
            continue
        try:
            if candidate.is_file() or candidate.is_symlink():
                candidate.unlink()
                removed.append(candidate)
        except OSError:
            pass
    return removed


def terminate_browser(process, graceful_timeout=3, forced_timeout=2, group_killer=os.killpg):
    """Gracefully stop our child, then kill only its dedicated process group."""
    if process.poll() is not None:
        return True
    try:
        process.terminate()
        process.wait(timeout=graceful_timeout)
        return True
    except ProcessLookupError:
        return True
    except subprocess.TimeoutExpired:
        try:
            group_killer(process.pid, signal.SIGKILL)
            process.wait(timeout=forced_timeout)
            return True
        except ProcessLookupError:
            return process.poll() is not None
        except subprocess.TimeoutExpired:
            return False


class ResetState:
    """Signal-safe counter: repeated reset requests coalesce before relaunch."""
    def __init__(self):
        self.generation = 0

    def request(self, _signum=None, _frame=None):
        self.generation += 1


def supervise_firefox(reset_state, process_factory=subprocess.Popen, sleeper=time.sleep,
                      profile=PROFILE, start_url_reader=read_validated_start_url):
    """Run one Firefox at a time; a reset stops, clears and relaunches it."""
    handled = reset_state.generation
    clear_session_restore(profile)
    while True:
        process = process_factory(firefox_command(start_url_reader()), start_new_session=True)
        while process.poll() is None and reset_state.generation == handled:
            sleeper(0.1)
        if reset_state.generation == handled:
            return process.returncode
        if not terminate_browser(process):
            return None
        clear_session_restore(profile)
        handled = reset_state.generation


def publish_supervisor_pid(pid, path=SUPERVISOR_PID):
    """Publish the fixed supervisor PID without following an existing link."""
    temporary = path.with_name("." + path.name + ".4tw-new")
    try:
        if os.path.lexists(temporary):
            temporary.unlink()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="ascii") as handle:
            handle.write(str(pid) + "\n")
        os.replace(temporary, path)
        return True
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass
        return False


def remove_supervisor_pid(pid, path=SUPERVISOR_PID):
    try:
        if path.read_text(encoding="ascii").strip() == str(pid):
            path.unlink()
    except OSError:
        pass


def _is_expected_supervisor(pid, proc_root=Path("/proc"), expected_uid=None):
    try:
        arguments = (proc_root / str(pid) / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
        status = (proc_root / str(pid) / "status").read_text(encoding="utf-8")
    except OSError:
        return False
    if (len(arguments) != 3 or arguments[1:] != [b"-I", SUPERVISOR_SCRIPT.encode()] or
            not Path(os.fsdecode(arguments[0])).name.startswith("python3")):
        return False
    if expected_uid is not None:
        uid_line = next((line for line in status.splitlines() if line.startswith("Uid:")), "")
        try:
            effective_uid = int(uid_line.split()[2])
        except (ValueError, IndexError):
            return False
        if effective_uid != expected_uid:
            return False
    return True


def request_return_home(pid_path=SUPERVISOR_PID, mode_path=MODE_PATH,
                        proc_root=Path("/proc"), killer=os.kill, expected_uid=None):
    """Signal only the validated Online kiosk supervisor; accept no URL/input."""
    try:
        if mode_path.read_text(encoding="utf-8").strip() != "online":
            return False
        raw_pid = pid_path.read_text(encoding="ascii").strip()
        if not raw_pid.isascii() or not raw_pid.isdecimal():
            return False
        pid = int(raw_pid)
    except (OSError, ValueError):
        return False
    uid = os.geteuid() if expected_uid is None else expected_uid
    if pid <= 1 or not _is_expected_supervisor(pid, proc_root, uid):
        return False
    try:
        killer(pid, signal.SIGUSR1)
        return True
    except (OSError, ProcessLookupError):
        return False
