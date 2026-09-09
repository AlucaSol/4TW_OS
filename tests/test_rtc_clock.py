#!/usr/bin/python3
"""Unit tests for the one-way local-RTC to Linux system-clock import."""
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "rootfs-overlay/usr/local/lib/4tw/rtc_clock.py"
spec = importlib.util.spec_from_file_location("rtc_clock", SOURCE)
rtc_clock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtc_clock)


class RtcClockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.rtc = self.root / "rtc0"
        self.rtc.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def write_clock(self, date="2026-09-09", clock="12:00:00"):
        (self.rtc / "date").write_text(date, encoding="ascii")
        (self.rtc / "time").write_text(clock, encoding="ascii")

    def test_reads_standard_sysfs_fields_without_a_device_node(self):
        self.write_clock()
        self.assertEqual(rtc_clock.read_local_rtc(self.root), datetime(2026, 9, 9, 12, 0, 0))

    def test_missing_malformed_and_implausible_values_fail_safely(self):
        self.assertIsNone(rtc_clock.read_local_rtc(self.root))
        self.write_clock(date="not-a-date")
        self.assertIsNone(rtc_clock.read_local_rtc(self.root))
        self.write_clock(date="1900-01-01")
        self.assertIsNone(rtc_clock.read_local_rtc(self.root))

    def test_local_wall_clock_is_converted_to_utc_epoch(self):
        wall = datetime(2026, 9, 9, 12, 0, 0)
        darwin_offset = timezone(timedelta(hours=9, minutes=30))
        expected = datetime(2026, 9, 9, 2, 30, 0, tzinfo=timezone.utc).timestamp()
        self.assertEqual(rtc_clock.local_wallclock_epoch(wall, zone=darwin_offset), expected)

    def test_import_sets_only_linux_realtime_clock(self):
        self.write_clock()
        calls = []
        zone_file = self.root / "localtime"
        zone_file.write_bytes(Path("/usr/share/zoneinfo/Australia/Darwin").read_bytes())
        result = rtc_clock.import_local_rtc(
            self.root, zone_file,
            setter=lambda clock_id, epoch: calls.append((clock_id, epoch)),
            clock_id=123,
        )
        self.assertEqual(result, "system-clock-initialized")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], 123)
        self.assertEqual(
            calls[0][1],
            datetime(2026, 9, 9, 2, 30, 0, tzinfo=timezone.utc).timestamp(),
        )

    def test_unavailable_rtc_never_calls_clock_setter(self):
        calls = []
        result = rtc_clock.import_local_rtc(
            self.root, self.root / "missing-zone",
            setter=lambda *_args: calls.append(True), clock_id=123,
        )
        self.assertEqual(result, "rtc-unavailable")
        self.assertEqual(calls, [])

    def test_source_has_no_command_or_rtc_device_write_path(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertNotIn("subprocess", source)
        self.assertNotIn("/dev/rtc", source)
        self.assertNotIn("os.open", source)
        self.assertIn('Path("/sys/class/rtc")', source)
        self.assertIn("clock_settime", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
