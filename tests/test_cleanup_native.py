#!/usr/bin/python3
from pathlib import Path
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
HELPER = PROJECT / "build/cleanup-native.sh"


class NativeCleanupSafetyTests(unittest.TestCase):
    def call(self, body):
        return subprocess.run(
            ["bash", "-Eeuo", "pipefail", "-c", 'source "$1"; ' + body,
             "cleanup-test", str(HELPER)],
            check=False, text=True, capture_output=True,
        )

    def test_unsafe_paths_fail_before_account_or_filesystem_actions(self):
        for path in ("/", "/root/4tw-ubuntu-sway-build",
                     "/mnt/c/4tw-ubuntu-sway-build", "/home/user/not-4tw"):
            result = self.call(f'set +e; validate_identity "{path}" writer; exit_code=$?; '
                               'set -e; [[ $exit_code == 20 ]]')
            self.assertEqual(result.returncode, 0, (path, result.stderr))

    def test_mount_filter_returns_only_exact_project_descendants(self):
        body = (
            "findmnt() { printf '%s\\n' / /home/writer/4tw-ubuntu-sway-build/.work/rootfs/dev "
            "/home/writer/other; }; "
            "result=$(project_mounts /home/writer/4tw-ubuntu-sway-build); "
            "[[ $result == /home/writer/4tw-ubuntu-sway-build/.work/rootfs/dev ]]"
        )
        result = self.call(body)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_generic_or_host_disk_cleanup_commands(self):
        text = HELPER.read_text(encoding="utf-8")
        forbidden = ("umount -a", "losetup -D", "rm -rf /", "/tmp/*", "apt-get clean")
        for value in forbidden:
            self.assertNotIn(value, text)
        self.assertIn('rm -rf --one-file-system -- "$build"', text)
        self.assertIn('backing == "$build/"*', text)
        self.assertIn('flock -n 9', text)
        self.assertIn('assert_no_process_uses_tree "$build"', text)

    def test_diagnostics_are_strict_machine_readable_fields(self):
        result = self.call("emit_status present /home/writer/4tw-ubuntu-sway-build writer 10 2 1 completed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "status=present",
            "path=/home/writer/4tw-ubuntu-sway-build",
            "selected_user=writer",
            "size_bytes=10",
            "mount_count=2",
            "loop_count=1",
            "vm_tools=completed",
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
