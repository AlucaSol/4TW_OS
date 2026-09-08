#!/usr/bin/python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error

PROJECT = Path(__file__).resolve().parents[1]
LIBRARY = PROJECT / "rootfs-overlay/usr/local/lib/4tw"

appliance_spec = importlib.util.spec_from_file_location("appliance", LIBRARY / "appliance.py")
appliance = importlib.util.module_from_spec(appliance_spec)
appliance_spec.loader.exec_module(appliance)
provider_spec = importlib.util.spec_from_file_location("timezone_provider", LIBRARY / "timezone_provider.py")
timezone_provider = importlib.util.module_from_spec(provider_spec)
provider_spec.loader.exec_module(timezone_provider)


class Response:
    def __init__(self, data, status=200):
        self.data = data
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, count):
        return self.data[:count]


class Opener:
    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        if self.error:
            raise self.error
        return self.response


class TimezoneTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.zoneinfo = self.root / "zoneinfo"
        for name in ("Etc/UTC", "Australia/Darwin", "Australia/Adelaide"):
            path = self.zoneinfo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"TZif")
        self.provider_config = self.root / "provider.json"
        self.provider_config.write_text(json.dumps({
            "name": "ipapi.co",
            "endpoint": "https://ipapi.co/timezone/",
            "response": "iana-text",
            "timeout_seconds": 4,
        }))

    def tearDown(self):
        self.temporary.cleanup()

    def test_provider_makes_one_minimal_bounded_request(self):
        opener = Opener(Response(b"Australia/Darwin\n"))
        self.assertEqual(timezone_provider.lookup_timezone(self.provider_config, opener), "Australia/Darwin")
        self.assertEqual(len(opener.calls), 1)
        request, timeout = opener.calls[0]
        self.assertEqual(request.full_url, "https://ipapi.co/timezone/")
        self.assertEqual(request.method, "GET")
        self.assertEqual(request.get_header("Accept"), "text/plain")
        self.assertEqual(timeout, 4)
        self.assertIsNone(timezone_provider.NoRedirect().redirect_request(None, None, 302, None, None, None))

    def test_provider_fails_closed(self):
        bad = (b"", b"{}", b'{"timezone":"Australia/Darwin"}', b"<html>",
               b"Australia/Darwin\nAustralia/Adelaide\n", b" Australia/Darwin\n",
               b"\xff", b"A" * 129)
        for response in bad:
            opener = Opener(Response(response))
            self.assertIsNone(timezone_provider.lookup_timezone(self.provider_config, opener), response[:20])
        opener = Opener(error=urllib.error.URLError("offline"))
        self.assertIsNone(timezone_provider.lookup_timezone(self.provider_config, opener))
        self.assertEqual(len(opener.calls), 1)
        opener = Opener(error=TimeoutError("timed out"))
        self.assertIsNone(timezone_provider.lookup_timezone(self.provider_config, opener))
        self.assertEqual(len(opener.calls), 1)

    def test_provider_config_cannot_redirect_or_change_scope(self):
        for change in (
            {"endpoint": "http://ipapi.co/timezone/"},
            {"endpoint": "https://example.com/timezone/"},
            {"endpoint": "https://ipapi.co/json/"},
            {"timeout_seconds": 30},
            {"extra": "field"},
        ):
            data = json.loads(self.provider_config.read_text())
            data.update(change)
            self.provider_config.write_text(json.dumps(data))
            self.assertIsNone(timezone_provider.lookup_timezone(self.provider_config, Opener(Response(b"Australia/Darwin"))))
            data.pop("extra", None)
            data.update({
                "name": "ipapi.co", "endpoint": "https://ipapi.co/timezone/",
                "response": "iana-text", "timeout_seconds": 4,
            })
            self.provider_config.write_text(json.dumps(data))

    def test_timezone_validation_and_fixed_timedatectl_arguments(self):
        calls = []

        def runner(arguments, **_kwargs):
            calls.append(arguments)
            return type("Result", (), {"returncode": 0})()

        localtime = self.root / "localtime"
        self.assertTrue(appliance.apply_timezone("Australia/Darwin", self.zoneinfo, localtime, runner))
        self.assertEqual(calls, [["/usr/bin/timedatectl", "set-timezone", "Australia/Darwin"]])
        for value in (None, "auto", "../Etc/UTC", "/etc/passwd", "Australia/Darwin;sh", "right/UTC"):
            self.assertIsNone(appliance.valid_timezone(value, self.zoneinfo))
        self.assertFalse(appliance.apply_timezone("$(sh)", self.zoneinfo, localtime, runner))
        self.assertEqual(len(calls), 1)

    def test_manual_override_never_calls_provider(self):
        mode = self.root / "mode"
        marker = self.root / "attempted"
        state = self.root / "state"
        mode.write_text("Australia/Darwin\n")

        def forbidden_provider():
            self.fail("manual override contacted the provider")

        result = appliance.automatic_timezone_once(
            forbidden_provider, mode, marker, state, self.zoneinfo,
            apply=lambda *_args, **_kwargs: True,
        )
        self.assertEqual(result, "manual-override")
        self.assertFalse(marker.exists())
        self.assertFalse(state.exists())

    def test_auto_lookup_runs_only_once_and_persists_changed_zone(self):
        mode = self.root / "mode"
        marker = self.root / "attempted"
        state = self.root / "state"
        mode.write_text("auto\n")
        calls = []
        applied = []

        def provider():
            calls.append(True)
            return "Australia/Darwin"

        def apply(zone, **_kwargs):
            applied.append(zone)
            return True

        self.assertEqual(appliance.automatic_timezone_once(
            provider, mode, marker, state, self.zoneinfo, apply), "updated")
        self.assertEqual(appliance.automatic_timezone_once(
            provider, mode, marker, state, self.zoneinfo, apply), "already-attempted")
        self.assertEqual(len(calls), 1)
        self.assertEqual(applied, ["Australia/Darwin"])
        self.assertEqual(state.read_text(), "Australia/Darwin\n")

        with mock.patch.object(appliance.os, "replace", wraps=appliance.os.replace) as replace:
            self.assertTrue(appliance.write_last_known("Australia/Darwin", state, self.zoneinfo))
            replace.assert_not_called()

    def test_failed_lookup_preserves_last_known_zone(self):
        mode = self.root / "mode"
        marker = self.root / "attempted"
        state = self.root / "state"
        mode.write_text("auto\n")
        state.write_text("Australia/Adelaide\n")
        result = appliance.automatic_timezone_once(
            lambda: "Not/AZone", mode, marker, state, self.zoneinfo,
            apply=lambda *_args, **_kwargs: self.fail("invalid timezone was applied"),
        )
        self.assertEqual(result, "lookup-failed")
        self.assertEqual(state.read_text(), "Australia/Adelaide\n")

    def test_auto_startup_uses_last_known_then_utc_fallback(self):
        state = self.root / "state"
        applied = []

        def apply(zone, **_kwargs):
            applied.append(zone)
            return True

        self.assertEqual(appliance.prepare_timezone("auto", state, self.zoneinfo, apply), ("Etc/UTC", True))
        state.write_text("Australia/Adelaide\n")
        self.assertEqual(appliance.prepare_timezone("auto", state, self.zoneinfo, apply),
                         ("Australia/Adelaide", True))
        self.assertEqual(applied, ["Etc/UTC", "Australia/Adelaide"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
