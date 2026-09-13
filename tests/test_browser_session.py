#!/usr/bin/python3
import importlib
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "rootfs-overlay/usr/local/lib/4tw"))
session = importlib.import_module("browser_session")


class FakeProcess:
    def __init__(self, forced=False, running=True, graceful_delay=0):
        self.pid = 424242
        self.forced = forced
        self.graceful_delay = graceful_delay
        self.simulated_elapsed = 0
        self.returncode = None if running else 0
        self.terminated = 0
        self.killed = 0
        self.wait_timeouts = []

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated += 1

    def kill(self):
        self.killed += 1
        self.returncode = -9

    def wait(self, timeout):
        self.wait_timeouts.append(timeout)
        if self.forced and not self.killed:
            raise subprocess.TimeoutExpired("firefox", timeout)
        self.simulated_elapsed += min(self.graceful_delay, timeout)
        self.returncode = self.returncode if self.returncode is not None else 0
        return self.returncode


class BrowserSession(unittest.TestCase):
    def test_normal_and_delayed_graceful_exit(self):
        normal = FakeProcess()
        delayed = FakeProcess(graceful_delay=1.5)
        self.assertTrue(session.terminate_browser(normal, graceful_timeout=3))
        self.assertTrue(session.terminate_browser(delayed, graceful_timeout=3))
        self.assertEqual((normal.terminated, normal.killed, normal.wait_timeouts), (1, 0, [3]))
        self.assertEqual((delayed.terminated, delayed.killed, delayed.wait_timeouts), (1, 0, [3]))
        self.assertEqual(delayed.simulated_elapsed, 1.5)

    def test_bounded_forced_exit(self):
        process = FakeProcess(forced=True)
        signals = []

        def kill_group(pid, requested_signal):
            signals.append((pid, requested_signal))
            process.kill()

        self.assertTrue(session.terminate_browser(
            process, graceful_timeout=3, forced_timeout=2, group_killer=kill_group))
        self.assertEqual((process.terminated, process.killed, process.wait_timeouts), (1, 1, [3, 2]))
        self.assertEqual(signals, [(process.pid, signal.SIGKILL)])

    def test_only_session_restore_state_is_removed(self):
        with tempfile.TemporaryDirectory() as folder:
            profile = Path(folder)
            backups = profile / "sessionstore-backups"
            backups.mkdir()
            removed = [profile / "sessionstore.jsonlz4", profile / "sessionCheckpoints.json",
                       backups / "recovery.jsonlz4", backups / "recovery.baklz4",
                       backups / "previous.jsonlz4", backups / "upgrade.jsonlz4-20260913"]
            retained = [profile / "cookies.sqlite", profile / "prefs.js",
                        profile / "storage.sqlite", backups / "unrelated.txt"]
            for path in removed + retained:
                path.write_text("test")
            session.clear_session_restore(profile)
            self.assertTrue(all(not path.exists() for path in removed))
            self.assertTrue(all(path.read_text() == "test" for path in retained))

    def test_return_home_signals_only_expected_online_supervisor(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pid = 1234
            pid_path = root / "browser.pid"
            mode_path = root / "mode"
            proc = root / "proc" / str(pid)
            proc.mkdir(parents=True)
            pid_path.write_text(str(pid))
            mode_path.write_text("online")
            (proc / "cmdline").write_bytes(
                b"/usr/bin/python3\0-I\0/usr/local/libexec/4tw-browser\0")
            (proc / "status").write_text("Name:\tpython3\nUid:\t1000\t1000\t1000\t1000\n")
            calls = []
            self.assertTrue(session.request_return_home(
                pid_path, mode_path, root / "proc", lambda *args: calls.append(args), 1000))
            self.assertEqual(calls, [(pid, signal.SIGUSR1)])
            (proc / "cmdline").write_bytes(b"/usr/bin/python3\0-I\0/tmp/unrelated\0")
            self.assertFalse(session.request_return_home(
                pid_path, mode_path, root / "proc", lambda *args: calls.append(args), 1000))
            mode_path.write_text("offline")
            self.assertFalse(session.request_return_home(
                pid_path, mode_path, root / "proc", lambda *args: calls.append(args), 1000))
            self.assertEqual(len(calls), 1)

    def test_repeated_requests_coalesce_without_process_accumulation(self):
        reset = session.ResetState()
        first = FakeProcess()
        second = FakeProcess(running=False)
        processes = [first, second]
        commands = []

        def factory(command, start_new_session):
            commands.append((command, start_new_session))
            return processes.pop(0)

        def request_twice(_delay):
            reset.request()
            reset.request()

        session.supervise_firefox(reset, factory, request_twice,
                                  start_url_reader=lambda: "https://example.com/")
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0], commands[1])
        self.assertEqual(commands[0], (session.firefox_command("https://example.com/"), True))
        self.assertEqual((first.terminated, first.killed), (1, 0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
