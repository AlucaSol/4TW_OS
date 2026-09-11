#!/usr/bin/python3
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class CompressReleaseTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0 or shutil.which("zstd") is None:
            self.skipTest("release-stage tests require the configured root WSL build host")
        self.temporary = tempfile.TemporaryDirectory(prefix="4tw release test ")
        self.project = Path(self.temporary.name)
        (self.project / "build").mkdir()
        (self.project / "artifacts").mkdir()
        (self.project / ".work").mkdir()
        for name in ("common.sh", "release-size.sh", "compress-release.sh"):
            shutil.copy2(PROJECT / "build" / name, self.project / "build" / name)
        self.image = self.project / "artifacts/4TW-OS_RELEASE.img"
        self.image.write_bytes((b"4TW-OS verified raw image\0" * 4096) + os.urandom(8192))
        self.mark_verified()

    def tearDown(self):
        self.temporary.cleanup()

    def mark_verified(self):
        digest = hashlib.sha256(self.image.read_bytes()).hexdigest()
        (self.project / "artifacts/4TW-OS_RELEASE.img.sha256").write_text(
            f"{digest}  4TW-OS_RELEASE.img\n", encoding="ascii")
        (self.project / ".work/verified-image.sha256").write_text(digest + "\n", encoding="ascii")
        (self.project / ".work/verified.ok").touch()
        return digest

    def run_stage(self, *arguments, environment=None):
        return subprocess.run(
            ["bash", str(self.project / "build/compress-release.sh"), *arguments],
            check=False, text=True, capture_output=True, env=environment)

    def test_success_integrity_checksum_and_source_binding(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.project / "artifacts/4TW-OS_RELEASE.img.zst"
        checksum = self.project / "artifacts/4TW-OS_RELEASE.img.zst.sha256"
        self.assertTrue(release.is_file())
        self.assertEqual(subprocess.run(["zstd", "--test", "--quiet", str(release)]).returncode, 0)
        release_hash = hashlib.sha256(release.read_bytes()).hexdigest()
        self.assertEqual(checksum.read_text().strip(), f"{release_hash}  4TW-OS_RELEASE.img.zst")
        self.assertEqual((self.project / "artifacts/4TW-OS_RELEASE.img.zst.source.sha256").read_text().split()[0],
                         self.mark_verified())
        self.assertIn("GitHub Release size check: PASS", result.stdout)

    def test_corruption_and_stale_raw_are_rejected_then_regenerated(self):
        self.assertEqual(self.run_stage().returncode, 0)
        release = self.project / "artifacts/4TW-OS_RELEASE.img.zst"
        release.write_bytes(b"corrupted zstd stream")
        self.assertEqual(self.run_stage("--status").returncode, 10)
        self.assertEqual(self.run_stage().returncode, 0)
        self.assertEqual(subprocess.run(["zstd", "--test", "--quiet", str(release)]).returncode, 0)

        previous_source = (self.project / "artifacts/4TW-OS_RELEASE.img.zst.source.sha256").read_text()
        self.image.write_bytes(b"different newly verified raw image")
        new_hash = self.mark_verified()
        self.assertNotIn(new_hash, previous_source)
        self.assertEqual(self.run_stage("--status").returncode, 10)
        self.assertEqual(self.run_stage().returncode, 0)
        self.assertEqual((self.project / "artifacts/4TW-OS_RELEASE.img.zst.source.sha256").read_text().split()[0],
                         new_hash)

    def test_compression_failure_preserves_raw_and_resumes(self):
        fake_bin = self.project / "fake-bin"
        fake_bin.mkdir()
        fake_zstd = fake_bin / "zstd"
        fake_zstd.write_text("#!/bin/sh\nexit 42\n", encoding="ascii")
        fake_zstd.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        failed = self.run_stage(environment=environment)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Release compression failed", failed.stderr)
        self.assertTrue(self.image.is_file())
        self.assertEqual(self.run_stage().returncode, 0)

    def test_size_boundary_and_host_dependency(self):
        command = (
            'source "$1"; github_release_size_report 2147483647 >/dev/null; '
            'pass=$?; set +e; github_release_size_report 2147483648 >/dev/null; fail=$?; '
            '[[ $pass == 0 && $fail == 3 ]]')
        result = subprocess.run(
            ["bash", "-c", command, "release-size-test", str(PROJECT / "build/release-size.sh")],
            check=False, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        setup = (PROJECT / "build/setup-host.sh").read_text(encoding="utf-8")
        self.assertIn("util-linux zstd", setup)
        source = (PROJECT / "build/compress-release.sh").read_text(encoding="utf-8")
        self.assertIn('zstd -T0 -10 --force "$IMAGE"', source)
        self.assertNotIn("--ultra", source)
        wrapper = (PROJECT / "build/run-wsl.sh").read_text(encoding="utf-8")
        self.assertIn("--exclude='*.img.zst'", wrapper)
        self.assertIn("--exclude='*.img.zst.partial'", wrapper)


if __name__ == "__main__":
    unittest.main(verbosity=2)
