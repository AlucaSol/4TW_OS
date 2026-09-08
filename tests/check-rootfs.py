#!/usr/bin/python3
"""Checks usable both before assembly and against the mounted final image."""
import ast
import json
from pathlib import Path
import re
import subprocess
import sys

root, project = map(Path, sys.argv[1:])
def read(path):
    return (root / path.lstrip("/")).read_text()
def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)
    print("PASS: " + message)

check('VERSION_ID="26.04"' in read("/usr/lib/os-release"), "Ubuntu 26.04 base")
check("MODEL=Release" in read("/etc/4tw-release"), "4TW-OS Release model")
policy = json.loads(read("/etc/firefox/policies/policies.json"))["policies"]
allow = json.loads(read("/etc/4tw/allowed-sites.json"))
check(policy["WebsiteFilter"] == {"Block": ["<all_urls>"], "Exceptions": allow}, "native WebsiteFilter blocks all other sites")
check(allow == json.loads((project / "config/allowed-sites.json").read_text()), "installed allowlist matches explicit source")
for key in ("DisableDeveloperTools", "BlockAboutConfig", "BlockAboutProfiles", "BlockAboutAddons", "DisablePrivateBrowsing"):
    check(policy.get(key) is True, key)
check(policy["DisableSecurityBypass"] == {"InvalidCertificate": True, "SafeBrowsing": True}, "TLS/certificate bypass prohibited")
check(policy["Preferences"]["browser.cache.disk.enable"]["Value"] is False, "Firefox disk cache disabled; profile remains persistent")
check(policy["Preferences"]["browser.cache.disk.parent_directory"]["Value"] == "/run/user/1000/cache/firefox",
      "Firefox disposable cache has a RAM-backed parent")
check(policy["Preferences"]["browser.sessionstore.interval"]["Value"] == 300000,
      "Firefox recovery snapshots are limited to five-minute intervals")
# Policy recognition is checked against Services.policies in the actual running
# Firefox by browser-smoke.py, not inferred from source or an archive schema.

sway = read("/etc/4tw/sway.conf")
active = [line.strip() for line in sway.splitlines() if line.strip() and not line.lstrip().startswith("#")]
check(not any(re.match(r"(include|bar|bindcode|mode|workspace)\b", line) for line in active), "Sway has no desktop includes, bar, workspace UI or hidden key modes")
expected = {
    "bindsym --inhibited --no-repeat Ctrl+Mod1+b exec /usr/local/bin/4tw-battery",
    "bindsym --inhibited Ctrl+Mod1+Left exec /usr/local/bin/4tw-brightness down",
    "bindsym --inhibited Ctrl+Mod1+Right exec /usr/local/bin/4tw-brightness up",
    "bindsym --inhibited --no-repeat Ctrl+Mod1+Delete exec /usr/bin/sudo -n /usr/local/sbin/4tw-poweroff",
    "exec /usr/local/libexec/4tw-browser",
}
check({line for line in active if " exec " in line or line.startswith("exec ")} == expected,
      "only four fixed global controls and one startup command are executable in Sway")
browser = read("/usr/local/libexec/4tw-browser")
tree = ast.parse(browser)
launches = [node for node in ast.walk(tree) if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "/usr/bin/firefox"]
check(len(launches) == 1 and len(launches[0].elts) == 6, "exactly one Firefox invocation with one positional start URL")
check('"--kiosk"' in browser and '"--profile"' in browser and 'LOCK_NB' in browser, "kiosk mode, persistent profile, single-instance launcher lock")
session = read("/usr/local/libexec/4tw-session")
check("MOZ_ENABLE_WAYLAND=1" in session and "WLR_DRM_DEVICES" in session and "/usr/local/bin/4tw-select-gpu" in session,
      "native Wayland and safe internal-panel DRM selection are configured")
for variable in ("DRI_PRIME", "__NV_PRIME_RENDER_OFFLOAD", "__GLX_VENDOR_LIBRARY_NAME", "VK_LAYER_NV_optimus"):
    check(variable in session, "discrete-GPU offload variable is cleared: " + variable)
acceleration_config = json.dumps(policy) + session + browser
for forbidden in ("layers.acceleration.disabled", "gfx.webrender.software", "LIBGL_ALWAYS_SOFTWARE", "WLR_RENDERER=pixman"):
    check(forbidden not in acceleration_config, "Firefox/Sway hardware acceleration is not disabled by " + forbidden)
check('"Homepage"' not in json.dumps(policy), "no redundant homepage launch policy")
check("/usr/bin/sudo -n /usr/local/sbin/4tw-poweroff" in read("/usr/local/libexec/4tw-session") and '"/usr/local/sbin/4tw-poweroff"' in browser,
      "browser/compositor exit requests poweroff, never falls into a shell")
sudoers = read("/etc/sudoers.d/4tw-kiosk")
check('NOPASSWD: /usr/local/sbin/4tw-poweroff "", /usr/local/sbin/4tw-backlight up, /usr/local/sbin/4tw-backlight down' in sudoers,
      "passwordless privileges limited to exact shutdown and brightness commands")
for path in ("usr/local/bin/4tw-battery", "usr/local/bin/4tw-brightness", "usr/local/bin/4tw-select-gpu",
             "usr/local/bin/4tw-power-status", "usr/local/sbin/4tw-backlight", "usr/local/sbin/4tw-poweroff",
             "usr/local/sbin/4tw-configure", "usr/local/sbin/4tw-power-setup", "usr/local/lib/4tw/appliance.py",
             "usr/local/lib/4tw/timezone_provider.py", "usr/local/libexec/4tw-timezone-auto",
             "etc/4tw/timezone-provider.json", "etc/NetworkManager/dispatcher.d/50-4tw-timezone",
             "etc/sudoers.d/4tw-kiosk"):
    stat = (root / path).stat()
    check(stat.st_uid == 0 and not stat.st_mode & 0o022, path + " is root-owned and not user-writable")
check("unmanaged-devices=type:ethernet" in read("/etc/NetworkManager/conf.d/4tw.conf"), "wired interfaces are unmanaged")
check((root / "etc/systemd/system/NetworkManager-wait-online.service").is_symlink(), "NetworkManager wait-online disabled")
check("TimeoutStartSec=35" in read("/etc/systemd/system/4tw-configure.service"), "Wi-Fi startup has a bounded timeout")
check("source " not in read("/usr/local/sbin/4tw-configure") and "shell=True" not in read("/usr/local/lib/4tw/appliance.py"), "config parser never sources shell code")
adjtime = [line.strip() for line in read("/etc/adjtime").splitlines() if line.strip()]
check(adjtime[-1] == "UTC" and "LOCAL" not in adjtime, "hardware RTC is explicitly interpreted as UTC")
check(read("/etc/timezone").strip() == "Etc/UTC", "fresh-install timezone fallback is Etc/UTC")
check((root / "etc/localtime").is_symlink() and (root / "etc/localtime").readlink() == Path("/usr/share/zoneinfo/Etc/UTC"),
      "fresh-install localtime uses the UTC zoneinfo entry")
chrony = read("/etc/chrony/chrony.conf")
check(any(line.strip() == "rtcsync" for line in chrony.splitlines()), "chrony retains normal UTC RTC synchronization")
check((root / "etc/systemd/system/multi-user.target.wants/chrony.service").is_symlink(),
      "chrony network-time synchronization is enabled")
check((project / "config/4tw.cfg").read_text().splitlines()[-1] == "timezone=auto",
      "writable CONFIG defaults to automatic timezone mode")
provider_config = json.loads(read("/etc/4tw/timezone-provider.json"))
check(provider_config == {"name": "ipapi.co", "endpoint": "https://ipapi.co/timezone/",
                          "response": "iana-text", "timeout_seconds": 4},
      "timezone provider is isolated to one HTTPS plain-text endpoint with a four-second timeout")
provider_source = read("/usr/local/lib/4tw/timezone_provider.py")
check("NoRedirect" in provider_source and "text/plain" in provider_source and "ssl._create_unverified_context" not in provider_source,
      "timezone request rejects redirects and does not weaken TLS")
timezone_service = read("/etc/systemd/system/4tw-timezone-auto.service")
check("ExecCondition=/usr/bin/nm-online -q --timeout=0" in timezone_service and
      "TimeoutStartSec=10" in timezone_service and "ProtectSystem=strict" in timezone_service,
      "automatic timezone lookup is connectivity-gated, bounded and sandboxed")
check(not (root / "etc/systemd/system/multi-user.target.wants/4tw-timezone-auto.service").exists(),
      "automatic timezone lookup is event-triggered rather than boot-blocking")
dispatcher = root / "etc/NetworkManager/dispatcher.d/50-4tw-timezone"
check(bool(dispatcher.stat().st_mode & 0o111) and "timezone-mode" in dispatcher.read_text(),
      "NetworkManager triggers the fixed helper only after connectivity in auto mode")
timezone_source = read("/usr/local/lib/4tw/appliance.py")
check("O_EXCL" in timezone_source and "timezone-attempted" in timezone_source and "/var/lib/4tw/timezone" in timezone_source,
      "one-attempt marker and last-known timezone state are implemented")
runtime_timezone_files = "\n".join(read(path) for path in (
    "/usr/local/lib/4tw/appliance.py", "/usr/local/lib/4tw/timezone_provider.py",
    "/usr/local/libexec/4tw-timezone-auto", "/etc/systemd/system/4tw-timezone-auto.service",
    "/etc/NetworkManager/dispatcher.d/50-4tw-timezone"))
check("set-local-rtc 1" not in runtime_timezone_files and "Australia/Adelaide" not in runtime_timezone_files,
      "runtime has no local-RTC command or hard-coded Australian timezone")
check("layer=overlay" in read("/etc/4tw/mako.conf") and "default-timeout=5000" in read("/etc/4tw/mako.conf"), "notification sits above fullscreen and automatically expires")
check((root / "usr/share/plymouth/themes/4tw/4TW-OS.png").read_bytes() == (project / "assets/4TW-OS.png").read_bytes(), "Plymouth logo is byte-identical to existing asset")
check("Math.Min" in read("/usr/share/plymouth/themes/4tw/4tw.script"), "Plymouth preserves image aspect ratio")
check("Storage=volatile" in read("/etc/systemd/journald.conf.d/4tw.conf"), "logs kept in RAM")
check("HandlePowerKey=poweroff" in read("/etc/systemd/logind.conf.d/4tw.conf"), "physical power button requests clean poweroff")
power_service = read("/etc/systemd/system/4tw-power-setup.service")
check("ExecStart=/usr/local/sbin/4tw-power-setup" in power_service and "TimeoutStartSec=5" in power_service,
      "fixed-purpose power policy runs once with a short timeout")
check((root / "etc/systemd/system/multi-user.target.wants/4tw-power-setup.service").is_symlink(),
      "power policy service is enabled")
for unit in ("dpkg-db-backup.timer", "e2scrub_all.timer", "e2scrub_reap.service", "motd-news.timer",
             "ua-timer.timer", "ubuntu-advantage.service", "ua-reboot-cmds.service"):
    check((root / "etc/systemd/system" / unit).is_symlink(), unit + " is disabled and masked")
power_source = read("/usr/local/lib/4tw/appliance.py")
check('"power/control", "auto"' in power_source and "NVIDIA_VENDOR" in power_source,
      "NVIDIA devices use normal runtime autosuspend rather than force-off")
check("balance_power" in power_source and "amd-pstate-epp" in power_source and "intel_pstate" in power_source,
      "modern CPU pstate policy prefers balance_power/powersave when supported")
check("bInterfaceClass" in power_source and '{"03", "08"}' in power_source and '{"block", "input", "net"}' in power_source,
      "USB autosuspend excludes storage, input and networking")
for helper in ("/usr/local/bin/4tw-select-gpu", "/usr/local/bin/4tw-power-status", "/usr/local/sbin/4tw-power-setup",
               "/usr/local/libexec/4tw-timezone-auto"):
    check("len(sys.argv) != 1" in read(helper), helper + " rejects all arguments")
passwd = {line.split(":")[0]: line.split(":") for line in read("/etc/passwd").splitlines()}
check(passwd["kiosk"][-1] == "/usr/local/libexec/4tw-session", "kiosk login program is not a normal shell")
installed = set(subprocess.check_output(["chroot", str(root), "dpkg-query", "-W", "-f=${Package}\n"], text=True).splitlines())
for package in ("openssh-server", "dropbear", "xterm", "foot", "gnome-terminal", "konsole", "nautilus", "thunar", "dolphin", "swaybar", "wofi", "rofi", "gdm3", "sddm", "lightdm", "snapd",
                "cups", "cups-daemon", "avahi-daemon", "bluez", "modemmanager", "packagekit", "power-profiles-daemon", "whoopsie",
                "geoclue-2.0", "libtimezonemap1", "libtimezonemap-data"):
    check(package not in installed, package + " is not installed")
check("chrony" in installed and "tzdata" in installed, "lightweight NTP and installed IANA timezone data are present")
check(not any(p.startswith("nvidia-driver-") for p in installed), "no proprietary high-power NVIDIA driver setup")
print("Root filesystem checks passed.")
