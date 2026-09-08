#!/usr/bin/python3
import importlib.util
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "build" / "resolve-native-build.py"
SPEC = importlib.util.spec_from_file_location("resolve_native_build", MODULE_PATH)
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


def account(name, uid, home, shell="/bin/bash"):
    return SimpleNamespace(pw_name=name, pw_uid=uid, pw_dir=home, pw_shell=shell)


class BuildPathTests(unittest.TestCase):
    def setUp(self):
        self.accounts = [
            account("root", 0, "/root"),
            account("fred", 2101, "/home/fred"),
            account("alice", 2102, "/home/alice"),
            account("service", 301, "/var/lib/service", "/usr/sbin/nologin"),
        ]
        self.bounds = (2000, 60000)

    def test_explicit_user_wins(self):
        chosen = resolver.choose_user(
            {"FOURTW_WSL_USER": "alice", "SUDO_USER": "fred"},
            self.accounts, "fred", self.bounds,
        )
        self.assertEqual(chosen.pw_name, "alice")

    def test_sudo_and_wsl_defaults(self):
        self.assertEqual(
            resolver.choose_user({"SUDO_USER": "fred"}, self.accounts, "alice", self.bounds).pw_name,
            "fred",
        )
        self.assertEqual(
            resolver.choose_user({}, self.accounts, "alice", self.bounds).pw_name,
            "alice",
        )

    def test_only_unambiguous_login_account_is_inferred(self):
        accounts = [self.accounts[0], self.accounts[1], self.accounts[3]]
        self.assertEqual(resolver.choose_user({}, accounts, None, self.bounds).pw_name, "fred")
        with self.assertRaises(resolver.ResolutionError):
            resolver.choose_user({}, self.accounts, None, self.bounds)

    def test_root_unknown_and_unsafe_homes_are_rejected(self):
        with self.assertRaises(resolver.ResolutionError):
            resolver.choose_user({"FOURTW_WSL_USER": "root"}, self.accounts, None, self.bounds)
        with self.assertRaises(resolver.ResolutionError):
            resolver.choose_user({"FOURTW_WSL_USER": "writer"}, self.accounts, None, self.bounds)
        unsafe = account("writer", 2103, "/mnt/c/Users/writer")
        with self.assertRaises(resolver.ResolutionError):
            resolver.native_build_directory(
                unsafe, is_dir=lambda path: True, resolve=lambda path: path,
            )
        linked = account("writer", 2103, "/home/writer")
        with self.assertRaises(resolver.ResolutionError):
            resolver.native_build_directory(
                linked, is_dir=lambda path: True,
                resolve=lambda path: Path("/mnt/c/Users/writer"),
            )

    def test_native_path_uses_selected_account_home(self):
        chosen = self.accounts[1]
        result = resolver.native_build_directory(
            chosen, is_dir=lambda path: True, resolve=lambda path: path,
        )
        self.assertEqual(result, Path("/home/fred/4tw-ubuntu-sway-build"))

    def test_wsl_conf_default_is_parsed(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "wsl.conf"
            config.write_text("[boot]\nsystemd=true\n[user]\ndefault=alice\n", encoding="utf-8")
            self.assertEqual(resolver.wsl_default_user(config), "alice")


class SourceAndCacheTests(unittest.TestCase):
    def setUp(self):
        self.project = Path(__file__).parents[1]

    @staticmethod
    def call_function(script, function, argument, environment=None):
        command = f'source "$1"; {function} "$2"'
        return subprocess.run(
            ["/bin/bash", "-Eeuo", "pipefail", "-c", command, "portability-test",
             str(script), str(argument)],
            check=False, text=True, capture_output=True, env=environment,
        )

    def test_source_copy_handles_spaces_and_uses_local_logo(self):
        with tempfile.TemporaryDirectory(prefix="4tw source ") as source_name, \
                tempfile.TemporaryDirectory(prefix="4tw destination ") as destination_name:
            source, destination = Path(source_name), Path(destination_name)
            (source / "assets").mkdir()
            (source / "assets/4TW-OS.png").write_bytes(b"project-local-logo")
            (source / "kept.txt").write_text("kept", encoding="utf-8")
            for ignored in (".git", ".work", ".build-cache", "artifacts", "prompts", "__pycache__"):
                (source / ignored).mkdir()
                (source / ignored / "ignored.txt").write_text("ignored", encoding="utf-8")
            result = subprocess.run(
                ["/bin/bash", "-Eeuo", "pipefail", "-c",
                 'source "$1"; sync_4tw_source "$2" "$3"', "portability-test",
                 str(self.project / "build/source-copy.sh"), str(source), str(destination)],
                check=False, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / "assets/4TW-OS.png").read_bytes(), b"project-local-logo")
            self.assertEqual((destination / "kept.txt").read_text(encoding="utf-8"), "kept")
            for ignored in (".git", ".work", ".build-cache", "prompts", "__pycache__"):
                self.assertFalse((destination / ignored).exists())

    def test_missing_logo_fails_clearly(self):
        with tempfile.TemporaryDirectory(prefix="4tw source ") as source_name, \
                tempfile.TemporaryDirectory(prefix="4tw destination ") as destination_name:
            result = subprocess.run(
                ["/bin/bash", "-Eeuo", "pipefail", "-c",
                 'source "$1"; sync_4tw_source "$2" "$3"', "portability-test",
                 str(self.project / "build/source-copy.sh"), source_name, destination_name],
                check=False, text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Required project logo", result.stderr)

    def test_real_checkout_copies_to_temporary_native_directory(self):
        with tempfile.TemporaryDirectory(prefix="4tw native copy ") as destination_name:
            destination = Path(destination_name)
            result = subprocess.run(
                ["/bin/bash", "-Eeuo", "pipefail", "-c",
                 'source "$1"; sync_4tw_source "$2" "$3"', "portability-test",
                 str(self.project / "build/source-copy.sh"), str(self.project), str(destination)],
                check=False, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (destination / "assets/4TW-OS.png").read_bytes(),
                (self.project / "assets/4TW-OS.png").read_bytes(),
            )
            self.assertTrue((destination / "build/run-wsl.sh").is_file())
            for ignored in (".git", ".work", ".build-cache", "prompts", "__pycache__"):
                self.assertFalse((destination / ignored).exists())
            self.assertEqual(list((destination / "artifacts").iterdir()), [])

    def test_missing_optional_cache_is_silent_and_successful(self):
        with tempfile.TemporaryDirectory(prefix="4tw cache ") as destination_name:
            environment = os.environ.copy()
            environment.pop("FOURTW_OLD_APT_CACHE", None)
            result = self.call_function(
                self.project / "build/cache-seed.sh", "seed_optional_apt_cache",
                destination_name, environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")

    def test_optional_cache_copies_only_missing_debs(self):
        with tempfile.TemporaryDirectory(prefix="4tw old cache ") as old_name, \
                tempfile.TemporaryDirectory(prefix="4tw new cache ") as destination_name:
            old, destination = Path(old_name), Path(destination_name)
            (old / "new.deb").write_bytes(b"new")
            (old / "ignored.txt").write_bytes(b"ignored")
            (destination / "existing.deb").write_bytes(b"existing")
            environment = os.environ.copy()
            environment["FOURTW_OLD_APT_CACHE"] = str(old)
            result = self.call_function(
                self.project / "build/cache-seed.sh", "seed_optional_apt_cache",
                destination, environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((destination / "new.deb").read_bytes(), b"new")
            self.assertEqual((destination / "existing.deb").read_bytes(), b"existing")
            self.assertFalse((destination / "ignored.txt").exists())
            self.assertEqual((old / "new.deb").read_bytes(), b"new")

    def test_tracked_source_has_no_original_machine_paths(self):
        forbidden = (
            "jon" + "be",
            "/home/" + "jon" + "be",
            "c:" + "\\" + "users" + "\\",
            "../" + "bcld",
            "bcld" + "-4thewords-build",
        )
        failures = []
        for path in self.project.rglob("*"):
            if (not path.is_file() or any(part in {".git", ".work", ".build-cache", "artifacts",
                                                   "prompts", "__pycache__"}
                                          for part in path.parts)):
                continue
            try:
                text = path.read_text(encoding="utf-8").casefold()
            except UnicodeError:
                continue
            for value in forbidden:
                if value.casefold() in text:
                    failures.append(f"{path.relative_to(self.project)}: {value}")
        self.assertEqual(failures, [])

    def test_repository_logo_and_ignore_rules(self):
        logo = self.project / "assets/4TW-OS.png"
        self.assertTrue(logo.is_file())
        self.assertFalse(logo.is_symlink())
        rules = (self.project / ".gitignore").read_text(encoding="utf-8").splitlines()
        for expected in ("artifacts/", ".work/", ".build-cache/", "__pycache__/"):
            self.assertIn(expected, rules)


if __name__ == "__main__":
    unittest.main()
