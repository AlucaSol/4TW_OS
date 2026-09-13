#!/usr/bin/python3
import base64
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "rootfs-overlay/usr/local/lib/4tw"))
spec = importlib.util.spec_from_file_location("appliance", PROJECT / "rootfs-overlay/usr/local/lib/4tw/appliance.py")
appliance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appliance)


class Helpers(unittest.TestCase):
    def battery(self, **fields):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bat = root / "BAT0"
            bat.mkdir()
            for key, value in fields.items():
                (bat / key).write_text(str(value))
            return appliance.battery_text(root)

    def test_battery_capacity_only(self):
        self.assertEqual(self.battery(capacity=72), "Battery: 72%")

    def test_battery_missing(self):
        self.assertEqual(self.battery(), "Battery information unavailable")
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(appliance.battery_text(Path(folder)), "Battery information unavailable")

    def test_battery_energy_power(self):
        result = self.battery(capacity=60, status="Discharging", power_now=10_000_000, energy_now=25_000_000)
        self.assertIn("Power draw: 10.0 W", result)
        self.assertIn("Estimated remaining: ~2h 30m", result)

    def test_battery_charge_current(self):
        result = self.battery(status="Discharging", current_now=2_000_000, voltage_now=12_000_000, charge_now=3_000_000)
        self.assertIn("Power draw: 24.0 W", result)
        self.assertIn("Estimated remaining: ~1h 30m", result)

    def test_battery_charging_is_not_runtime(self):
        result = self.battery(capacity=80, status="Charging", power_now=10_000_000, energy_now=25_000_000)
        self.assertIn("Status: Charging", result)
        self.assertNotIn("remaining", result)

    def test_battery_no_invented_estimate(self):
        for fields in (
            dict(status="Discharging", capacity=80),
            dict(status="Discharging", power_now=0, energy_now=25_000_000),
            dict(status="Discharging", power_now="nan", energy_now="inf"),
            dict(status="Discharging", energy_now=25_000_000, current_now=2_000_000, voltage_now=12_000_000),
        ):
            self.assertNotIn("remaining", self.battery(**fields))

    def test_untrusted_status_not_displayed(self):
        self.assertEqual(self.battery(status="$(touch /tmp/unsafe)", capacity=50), "Battery: 50%")

    def test_discrete_gpu_status(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            gpu = root / "0000:01:00.0"
            (gpu / "power").mkdir(parents=True)
            (gpu / "vendor").write_text("0x10de")
            (gpu / "class").write_text("0x030000")
            (gpu / "power/runtime_status").write_text("suspended")
            self.assertEqual(appliance.discrete_gpu_status(root), "suspended")
            (gpu / "power/runtime_status").write_text("active")
            self.assertEqual(appliance.discrete_gpu_status(root), "active")
            (gpu / "power/runtime_status").unlink()
            self.assertEqual(appliance.discrete_gpu_status(root), "unavailable")

    def test_internal_panel_gpu_selection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            drm, dev = root / "drm", root / "dev"
            drm.mkdir()
            dev.mkdir()
            for name, vendor in (("card0", "0x1002"), ("card1", "0x10de")):
                (drm / name / "device").mkdir(parents=True)
                (drm / name / "device/vendor").write_text(vendor)
                (dev / name).touch()
            connector = drm / "card0-eDP-1"
            connector.mkdir()
            (connector / "status").write_text("connected")
            self.assertEqual(appliance.preferred_drm_device(drm, dev), str(dev / "card0"))
            self.assertEqual(appliance.integrated_drm_device(drm, dev), str(dev / "card0"))
            (connector / "status").write_text("disconnected")
            self.assertIsNone(appliance.preferred_drm_device(drm, dev))

    def test_power_policy_is_conservative(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            pci, cpu, usb = root / "pci", root / "cpu", root / "usb"
            pci.mkdir()
            cpu.mkdir()
            usb.mkdir()
            for name, device_class in (("0000:01:00.0", "0x030000"), ("0000:01:00.1", "0x040300")):
                device = pci / name
                (device / "power").mkdir(parents=True)
                (device / "vendor").write_text("0x10de")
                (device / "class").write_text(device_class)
                (device / "power/control").write_text("on")
            policy = cpu / "cpufreq/policy0"
            policy.mkdir(parents=True)
            (policy / "energy_performance_available_preferences").write_text("performance balance_power power")
            (policy / "energy_performance_preference").write_text("performance")
            (policy / "scaling_driver").write_text("amd-pstate-epp")
            (policy / "scaling_available_governors").write_text("performance powersave")
            (policy / "scaling_governor").write_text("performance")
            safe = usb / "1-2"
            (safe / "power").mkdir(parents=True)
            (safe / "idVendor").write_text("1234")
            (safe / "power/control").write_text("on")
            (safe / "power/autosuspend_delay_ms").write_text("-1")
            storage = usb / "1-3"
            (storage / "power").mkdir(parents=True)
            (storage / "idVendor").write_text("5678")
            (storage / "power/control").write_text("on")
            interface = usb / "1-3:1.0"
            interface.mkdir()
            (interface / "bInterfaceClass").write_text("08")
            result = appliance.apply_power_policy(pci, cpu, usb)
            self.assertEqual(result, {"nvidia": 2, "cpu": 1, "usb": 1})
            self.assertEqual((pci / "0000:01:00.0/power/control").read_text(), "auto")
            self.assertEqual((pci / "0000:01:00.1/power/control").read_text(), "auto")
            self.assertEqual((policy / "energy_performance_preference").read_text(), "balance_power")
            self.assertEqual((policy / "scaling_governor").read_text(), "powersave")
            self.assertEqual((safe / "power/control").read_text(), "auto")
            self.assertEqual((safe / "power/autosuspend_delay_ms").read_text(), "2000")
            self.assertEqual((storage / "power/control").read_text(), "on")

    def test_backlight_steps_and_clamp(self):
        self.assertEqual(appliance.backlight_target(500, 1000, "up"), (600, 60))
        self.assertEqual(appliance.backlight_target(500, 1000, "down"), (400, 40))
        self.assertEqual(appliance.backlight_target(100, 1000, "down"), (100, 10))
        self.assertEqual(appliance.backlight_target(1000, 1000, "up"), (1000, 100))
        self.assertEqual(appliance.backlight_target(1000, 1000, "default"), (500, 50))
        with self.assertRaises(ValueError):
            appliance.backlight_target(100, 1000, ";sh")

    def test_backlight_writes_integer_and_handles_missing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertIsNone(appliance.set_backlight("up", root))
            dev = root / "generic-panel"
            dev.mkdir()
            (dev / "max_brightness").write_text("1000")
            (dev / "brightness").write_text("950")
            self.assertEqual(appliance.set_backlight("up", root), 100)
            self.assertEqual((dev / "brightness").read_text(), "1000")

    def test_keyboard_backlight_native_steps_clamp_and_off(self):
        self.assertEqual(appliance.keyboard_backlight_target(2, 3, "up"), (3, 100))
        self.assertEqual(appliance.keyboard_backlight_target(3, 3, "up"), (3, 100))
        self.assertEqual(appliance.keyboard_backlight_target(2, 3, "down"), (1, 33))
        self.assertEqual(appliance.keyboard_backlight_target(1, 3, "down"), (0, 0))
        self.assertEqual(appliance.keyboard_backlight_target(2, 3, "off"), (0, 0))
        self.assertEqual(appliance.keyboard_backlight_target(128, 255, "up"), (154, 60))
        with self.assertRaises(ValueError):
            appliance.keyboard_backlight_target(1, 3, "/bin/sh")

    def test_keyboard_backlight_detects_only_keyboard_led(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, current, maximum in (("input3::capslock", 1, 1), ("acer::mail", 1, 1),
                                           ("platform::kbd_backlight", 2, 3)):
                device = root / name
                device.mkdir()
                (device / "brightness").write_text(str(current))
                (device / "max_brightness").write_text(str(maximum))
            info = appliance.keyboard_backlight_info(root)
            self.assertEqual(info["name"], "platform::kbd_backlight")
            self.assertEqual(appliance.set_keyboard_backlight("down", root), 33)
            self.assertEqual((root / "platform::kbd_backlight/brightness").read_text(), "1")
            self.assertEqual((root / "input3::capslock/brightness").read_text(), "1")
            self.assertEqual(appliance.set_keyboard_backlight("off", root), 0)
            self.assertEqual((root / "platform::kbd_backlight/brightness").read_text(), "0")
            with self.assertRaises(ValueError):
                appliance.set_keyboard_backlight("../../tmp/unsafe", root)

    def test_keyboard_backlight_missing_and_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            leds, inputs, modules = root / "leds", root / "input", root / "modules"
            leds.mkdir()
            inputs.mkdir()
            modules.mkdir()
            self.assertIsNone(appliance.set_keyboard_backlight("up", leds))
            report = appliance.keyboard_backlight_diagnostics(leds, inputs, modules)
            self.assertIn("Acer WMI: unavailable", report)
            self.assertIn("Keyboard backlight:\n    unavailable", report)

            (modules / "acer_wmi").mkdir()
            device = leds / "acer:rgb:kbd_backlight"
            device.mkdir()
            (device / "brightness").write_text("3")
            (device / "max_brightness").write_text("3")
            event = inputs / "event8/device"
            (event / "capabilities").mkdir(parents=True)
            (event / "name").write_text("Acer WMI hotkeys")
            (event / "capabilities/key").write_text(hex((1 << 229) | (1 << 230))[2:])
            report = appliance.keyboard_backlight_diagnostics(leds, inputs, modules)
            self.assertIn("Acer WMI: loaded", report)
            self.assertIn("acer:rgb:kbd_backlight", report)
            self.assertIn("KEY_KBDILLUMDOWN, KEY_KBDILLUMUP", report)
            self.assertIn("current level: 3", report)
            self.assertIn("maximum level: 3", report)

    def test_start_url_and_hostname_validation(self):
        self.assertEqual(appliance.valid_start_url("HTTPS://Writing.Example.com/path?q=x"),
                         "https://writing.example.com/path?q=x")
        self.assertEqual(appliance.valid_start_url("http://example.com/"), "http://example.com/")
        for url in ("file:///etc/passwd", "javascript:alert(1)", "https://u@example.com/",
                    "https://example.com/\nanything", "https://example.com:bad/", "https://[bad/",
                    "https://example.com/;touch", "https://*.example.com/"):
            self.assertIsNone(appliance.valid_start_url(url), url)
        for hostname in ("*.example.com", "https://example.com", "example.com/path", "bad_name.example"):
            self.assertIsNone(appliance.valid_hostname(hostname), hostname)

    def test_default_config_is_credential_free(self):
        config = appliance.parse_config((PROJECT / "config/4tw.cfg").read_text())
        self.assertEqual((config.start_url, config.ssid, config.psk, config.timezone,
                          config.keyboard_backlight, config.site_lock, config.allowed_extra_domains),
                         ("https://4thewords.com/", b"", "", "auto", "off", "auto", ()))
        self.assertEqual(config.diagnostics, ())

    def test_config_key_validation(self):
        for value in ("command=sh", "wifi_ssid_b64=\nwifi_ssid_b64=",
                      "wifi_ssid_b64=%%", "keyboard_backlight=/bin/sh", "no equals"):
            with self.assertRaises(ValueError):
                appliance.parse_config(value)

    def test_config_shell_text_is_just_data(self):
        ssid = b"$(touch /tmp/unsafe);wifi"
        psk = "pass;$(id)\\ word"
        config = "wifi_ssid_b64=" + base64.b64encode(ssid).decode() + "\nwifi_psk_b64=" + base64.b64encode(psk.encode()).decode()
        parsed = appliance.parse_config(config)
        self.assertEqual(parsed.ssid, ssid)
        self.assertEqual(parsed.psk, psk)
        self.assertEqual(parsed.timezone, "auto")
        self.assertEqual(parsed.keyboard_backlight, "off")
        keyfile = appliance.nm_keyfile(parsed.ssid, parsed.psk)
        self.assertIn("psk=pass;$(id)\\\\\\sword", keyfile)
        self.assertNotIn("ssid=$(", keyfile)

    def test_timezone_config_is_validated_as_data(self):
        with tempfile.TemporaryDirectory() as folder:
            zoneinfo = Path(folder)
            zone = zoneinfo / "Australia/Darwin"
            zone.parent.mkdir()
            zone.write_bytes(b"TZif")
            parsed = appliance.parse_config("timezone=Australia/Darwin", zoneinfo)
            self.assertEqual(parsed.timezone, "Australia/Darwin")
            for value in ("../../etc/passwd", "/etc/passwd", "Australia/../Darwin",
                          "$(touch /tmp/unsafe)", "Australia/Darwin;sh", "Not/AZone"):
                parsed = appliance.parse_config("timezone=" + value, zoneinfo)
                self.assertEqual(parsed.timezone, "auto", value)

    def test_keyboard_backlight_config_is_fixed_data(self):
        self.assertEqual(appliance.parse_config("keyboard_backlight=keep").keyboard_backlight, "keep")
        self.assertEqual(appliance.parse_config("keyboard_backlight=off").keyboard_backlight, "off")


if __name__ == "__main__":
    unittest.main(verbosity=2)
