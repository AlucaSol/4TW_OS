#!/usr/bin/python3
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "rootfs-overlay/usr/local/lib/4tw"))
spec = importlib.util.spec_from_file_location("appliance", PROJECT / "rootfs-overlay/usr/local/lib/4tw/appliance.py")
appliance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appliance)
BASE = json.loads((PROJECT / "policies/policies.json").read_text())


class SitePolicy(unittest.TestCase):
    def policy(self, text):
        config = appliance.parse_config(text)
        return config, appliance.render_firefox_policy(
            BASE, config.start_url, config.site_lock, config.allowed_extra_domains)

    def test_default_host_and_subdomains(self):
        config, policy = self.policy("start_url=https://4thewords.com/\nsite_lock=auto")
        self.assertEqual(config.start_url, "https://4thewords.com/")
        self.assertEqual(policy["policies"]["WebsiteFilter"], {
            "Block": ["<all_urls>"],
            "Exceptions": ["https://4thewords.com/*", "https://*.4thewords.com/*"],
        })

    def test_path_does_not_broaden_configured_hostname(self):
        _, policy = self.policy("start_url=https://example.com/path\nsite_lock=auto")
        self.assertEqual(policy["policies"]["WebsiteFilter"]["Exceptions"], [
            "https://example.com/*", "https://*.example.com/*",
        ])
        _, nested = self.policy("start_url=https://writing.example.com/path\nsite_lock=auto")
        self.assertNotIn("https://example.com/*", nested["policies"]["WebsiteFilter"]["Exceptions"])

    def test_valid_extra_domains_are_added_and_invalid_entries_ignored(self):
        config, policy = self.policy(
            "start_url=https://example.com/\nsite_lock=auto\n"
            "allowed_extra_domains= accounts.example.com,*.injected.example, cdn.example.net,example.com/path")
        self.assertEqual(config.allowed_extra_domains, ("accounts.example.com", "cdn.example.net"))
        self.assertEqual(policy["policies"]["WebsiteFilter"]["Exceptions"], [
            "https://example.com/*", "https://*.example.com/*",
            "https://accounts.example.com/*", "https://cdn.example.net/*",
        ])
        self.assertNotIn("https://*.cdn.example.net/*", policy["policies"]["WebsiteFilter"]["Exceptions"])
        self.assertEqual(len(config.diagnostics), 2)

    def test_site_lock_off_removes_only_website_filter(self):
        locked = appliance.render_firefox_policy(BASE, "https://example.com/", "auto")
        unlocked = appliance.render_firefox_policy(locked, "https://example.com/", "off")
        self.assertNotIn("WebsiteFilter", unlocked["policies"])
        expected = json.loads(json.dumps(BASE))
        expected["policies"].pop("WebsiteFilter", None)
        self.assertEqual(unlocked, expected)

    def test_malformed_url_and_lock_fall_back_safely(self):
        config, policy = self.policy("start_url=file:///etc/passwd\nsite_lock=anything")
        self.assertEqual(config.start_url, appliance.DEFAULT_URL)
        self.assertEqual(config.site_lock, "auto")
        self.assertEqual(policy["policies"]["WebsiteFilter"]["Exceptions"], [
            "https://4thewords.com/*", "https://*.4thewords.com/*",
        ])
        self.assertEqual(len(config.diagnostics), 2)

    def test_injection_like_config_is_data_and_never_policy_json(self):
        config, policy = self.policy(
            "start_url=https://example.com/;touch-/tmp/pwned\n"
            "allowed_extra_domains=good.example,evil.example/\"}],\"DisableDeveloperTools\":false")
        self.assertEqual(config.start_url, appliance.DEFAULT_URL)
        self.assertEqual(config.allowed_extra_domains, ("good.example",))
        self.assertTrue(policy["policies"]["DisableDeveloperTools"])
        self.assertNotIn("evil.example", json.dumps(policy))

    def test_atomic_writer_skips_unchanged_policy(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            template = root / "base.json"
            destination = root / "policies.json"
            template.write_text(json.dumps(BASE))
            self.assertTrue(appliance.write_firefox_policy(
                "https://example.com/", "auto", (), template, destination))
            before = destination.stat().st_mtime_ns
            self.assertFalse(appliance.write_firefox_policy(
                "https://example.com/", "auto", (), template, destination))
            self.assertEqual(destination.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
