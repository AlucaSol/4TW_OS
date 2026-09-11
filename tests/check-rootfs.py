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
online_sway = read("/etc/4tw/sway-online.conf")
offline_sway = read("/etc/4tw/sway-offline.conf")
active = [line.strip() for line in sway.splitlines() if line.strip() and not line.lstrip().startswith("#")]
online_active = [line.strip() for line in online_sway.splitlines() if line.strip() and not line.lstrip().startswith("#")]
offline_active = [line.strip() for line in offline_sway.splitlines() if line.strip() and not line.lstrip().startswith("#")]
check(not any(re.match(r"(bar|bindcode|mode|workspace)\b", line) for line in active + online_active + offline_active),
      "Sway has no bar, workspace UI or hidden key modes")
expected = {
    "bindsym --inhibited --no-repeat Ctrl+Mod1+b exec /usr/local/bin/4tw-battery",
    "bindsym --inhibited Ctrl+Mod1+Left exec /usr/local/bin/4tw-brightness down",
    "bindsym --inhibited Ctrl+Mod1+Right exec /usr/local/bin/4tw-brightness up",
    "bindsym --inhibited XF86KbdBrightnessDown exec /usr/local/bin/4tw-keyboard-brightness down",
    "bindsym --inhibited XF86KbdBrightnessUp exec /usr/local/bin/4tw-keyboard-brightness up",
    "bindsym --inhibited --no-repeat Ctrl+Mod1+Delete exec /usr/bin/sudo -n /usr/local/sbin/4tw-poweroff",
}
check({line for line in active if " exec " in line or line.startswith("exec ")} == expected,
      "only the six fixed global appliance controls are executable in shared Sway")
check("XF86MonBrightness" not in sway and "XF86KbdBrightness" in sway and
      "F11 exec" not in sway and "F12 exec" not in sway,
      "keyboard illumination keys are distinct from LCD and ordinary F11/F12 bindings")
check(online_active[0] == "include /etc/4tw/sway.conf" and
      {line for line in online_active if line.startswith("exec ")} == {"exec /usr/local/libexec/4tw-online"},
      "Online mode includes only the shared controls and fixed Online launcher")
check(offline_active == ["include /etc/4tw/sway.conf", "exec /usr/local/libexec/4tw-typewriter"],
      "Offline mode includes only shared controls and the fixed typewriter launcher")
check('for_window [app_id="focuswriter" title="^FocusWriter$"] fullscreen enable' in active,
      "only the FocusWriter main window is forced fullscreen; its dialogs remain transient")
check("Ctrl+n nop" in online_sway and "Ctrl+o nop" in online_sway and "Ctrl+s nop" in online_sway and
      "Ctrl+n nop" not in offline_sway and "Ctrl+o nop" not in offline_sway and "Ctrl+s nop" not in offline_sway,
      "document New/Open/Save shortcuts remain available only in Offline mode")
browser = read("/usr/local/libexec/4tw-browser")
tree = ast.parse(browser)
launches = [node for node in ast.walk(tree) if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "/usr/bin/firefox"]
check(len(launches) == 1 and len(launches[0].elts) == 6, "exactly one Firefox invocation with one positional start URL")
check('"--kiosk"' in browser and '"--profile"' in browser and 'LOCK_NB' in browser, "kiosk mode, persistent profile, single-instance launcher lock")
online = read("/usr/local/libexec/4tw-online")
for label, command in (("Retry Wi-Fi", "/usr/local/sbin/4tw-retry-wifi"),
                       ("Offline Typewriter", "/usr/local/libexec/4tw-switch-offline"),
                       ("Shut Down", "/usr/local/sbin/4tw-poweroff")):
    check(label in online and command in online, "fixed Wi-Fi failure action exists: " + label)
check("--button-no-terminal" in online and "subprocess.Popen" in online and
      'status == "connected"' in online and "prompt.terminate()" in online and
      "/usr/bin/swaynag" in online and "input" not in online,
      "Wi-Fi failure UI remains visible for asynchronous fixed actions and closes on success")
typewriter = read("/usr/local/libexec/4tw-typewriter")
typewriter_tree = ast.parse(typewriter)
focuswriter_launches = [node for node in ast.walk(typewriter_tree) if isinstance(node, ast.List) and node.elts and
                        isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "/usr/bin/focuswriter"]
check(len(focuswriter_launches) == 1 and len(focuswriter_launches[0].elts) == 2,
      "exactly one FocusWriter invocation receives exactly one selected document")
check('"DefaultFormat": "txt"' in typewriter and '"Location": "/writing/Drafts"' in typewriter and
      'XDG_DATA_HOME"] = "/home/kiosk/.local/share"' in typewriter,
      "FocusWriter defaults to text/Drafts and keeps emergency recovery persistently")
session = read("/usr/local/libexec/4tw-session")
check("MOZ_ENABLE_WAYLAND=1" in session and "WLR_DRM_DEVICES" in session and "/usr/local/bin/4tw-select-gpu" in session,
      "native Wayland and safe internal-panel DRM selection are configured")
check("sway-online.conf" in session and "sway-offline.conf" in session and
      '[ "$mode" = online ] && [ "$next" = offline ]' in session,
      "session selects one mode and permits only the fixed same-boot Online-to-Offline transition")
for variable in ("DRI_PRIME", "__NV_PRIME_RENDER_OFFLOAD", "__GLX_VENDOR_LIBRARY_NAME", "VK_LAYER_NV_optimus"):
    check(variable in session, "discrete-GPU offload variable is cleared: " + variable)
acceleration_config = json.dumps(policy) + session + browser
for forbidden in ("layers.acceleration.disabled", "gfx.webrender.software", "LIBGL_ALWAYS_SOFTWARE", "WLR_RENDERER=pixman"):
    check(forbidden not in acceleration_config, "Firefox/Sway hardware acceleration is not disabled by " + forbidden)
check('"Homepage"' not in json.dumps(policy), "no redundant homepage launch policy")
check("/usr/bin/sudo -n /usr/local/sbin/4tw-poweroff" in read("/usr/local/libexec/4tw-session") and '"/usr/local/sbin/4tw-poweroff"' in browser,
      "browser/compositor exit requests poweroff, never falls into a shell")
sudoers = read("/etc/sudoers.d/4tw-kiosk")
check('NOPASSWD: /usr/local/sbin/4tw-poweroff "", /usr/local/sbin/4tw-backlight up, /usr/local/sbin/4tw-backlight down, /usr/local/sbin/4tw-keyboard-backlight up, /usr/local/sbin/4tw-keyboard-backlight down, /usr/local/sbin/4tw-retry-wifi "", /usr/local/sbin/4tw-enter-offline ""' in sudoers,
      "passwordless privileges limited to exact appliance shutdown, display/keyboard brightness, Wi-Fi retry and Offline transition")
for path in ("usr/local/bin/4tw-battery", "usr/local/bin/4tw-brightness", "usr/local/bin/4tw-keyboard-brightness",
             "usr/local/bin/4tw-select-gpu", "usr/local/bin/4tw-power-status", "usr/local/sbin/4tw-backlight",
             "usr/local/sbin/4tw-keyboard-backlight", "usr/local/sbin/4tw-poweroff",
             "usr/local/sbin/4tw-configure", "usr/local/sbin/4tw-power-setup", "usr/local/lib/4tw/appliance.py",
             "usr/local/lib/4tw/rtc_clock.py", "usr/local/lib/4tw/timezone_provider.py", "usr/local/libexec/4tw-timezone-auto",
             "usr/local/libexec/4tw-online", "usr/local/libexec/4tw-switch-offline", "usr/local/libexec/4tw-typewriter",
             "usr/local/sbin/4tw-retry-wifi", "usr/local/sbin/4tw-enter-offline",
             "etc/4tw/timezone-provider.json", "etc/NetworkManager/dispatcher.d/50-4tw-timezone",
             "etc/sudoers.d/4tw-kiosk"):
    stat = (root / path).stat()
    check(stat.st_uid == 0 and not stat.st_mode & 0o022, path + " is root-owned and not user-writable")
check("unmanaged-devices=type:ethernet" in read("/etc/NetworkManager/conf.d/4tw.conf"), "wired interfaces are unmanaged")
check((root / "etc/systemd/system/NetworkManager-wait-online.service").is_symlink(), "NetworkManager wait-online disabled")
check(not (root / "etc/systemd/system/multi-user.target.wants/NetworkManager.service").exists(),
      "NetworkManager is started only by Online mode, not globally at boot")
check("TimeoutStartSec=35" in read("/etc/systemd/system/4tw-configure.service"), "Wi-Fi startup has a bounded timeout")
check("Wants=NetworkManager.service" not in read("/etc/systemd/system/4tw-configure.service"),
      "Offline configuration does not acquire a NetworkManager dependency")
check("source " not in read("/usr/local/sbin/4tw-configure") and "shell=True" not in read("/usr/local/lib/4tw/appliance.py"), "config parser never sources shell code")
check(not (root / "etc/adjtime").exists(),
      "no persistent local-RTC or Linux RTC-maintenance state is installed")
check(read("/etc/timezone").strip() == "Etc/UTC", "fresh-install timezone fallback is Etc/UTC")
check((root / "etc/localtime").is_symlink() and (root / "etc/localtime").readlink() == Path("/usr/share/zoneinfo/Etc/UTC"),
      "fresh-install localtime uses the UTC zoneinfo entry")
chrony = read("/etc/chrony/chrony.conf")
chrony_active = [line.split("#", 1)[0].strip() for line in chrony.splitlines()
                  if line.split("#", 1)[0].strip()]
check(not any(line.split(None, 1)[0] in {"rtcsync", "rtcfile", "rtcautotrim"}
              for line in chrony_active), "chrony has no active physical-RTC directive")
check(any(line.split(None, 1)[0] == "makestep" for line in chrony_active),
      "chrony retains Linux system-clock stepping")
check((root / "etc/systemd/system/multi-user.target.wants/chrony.service").is_symlink(),
      "chrony network-time synchronization is enabled")
chrony_no_rtc = read("/etc/systemd/system/chrony.service.d/4tw-no-rtc.conf")
check("DevicePolicy=closed" in chrony_no_rtc and "DeviceAllow=" in chrony_no_rtc,
      "chronyd cannot open the physical RTC device")
for rtc_unit in ("hwclock.service", "hwclock-save.service", "systemd-hwclock-save.service"):
    rtc_unit_path = root / "etc/systemd/system" / rtc_unit
    check(rtc_unit_path.is_symlink() and rtc_unit_path.readlink() == Path("/dev/null"),
          rtc_unit + " is masked")
config_defaults = (project / "config/4tw.cfg").read_text().splitlines()
check("timezone=auto" in config_defaults, "writable CONFIG defaults to automatic timezone mode")
check("keyboard_backlight=off" in config_defaults,
      "writable CONFIG defaults to keyboard illumination off when a standard LED is detected")
provider_config = json.loads(read("/etc/4tw/timezone-provider.json"))
check(provider_config == {"name": "ipapi.co", "endpoint": "https://ipapi.co/timezone/",
                          "response": "iana-text", "timeout_seconds": 4},
      "timezone provider is isolated to one HTTPS plain-text endpoint with a four-second timeout")
provider_source = read("/usr/local/lib/4tw/timezone_provider.py")
check("NoRedirect" in provider_source and "text/plain" in provider_source and "ssl._create_unverified_context" not in provider_source,
      "timezone request rejects redirects and does not weaken TLS")
timezone_service = read("/etc/systemd/system/4tw-timezone-auto.service")
check("ExecCondition=/usr/bin/nm-online -q --timeout=0" in timezone_service and
      "TimeoutStartSec=10" in timezone_service and "ProtectSystem=strict" in timezone_service and
      "ReadWritePaths=/etc /run/4tw /var/lib/4tw" in timezone_service,
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
check("timedatectl" not in runtime_timezone_files and "Australia/Adelaide" not in runtime_timezone_files,
      "runtime timezone changes use zoneinfo files, with no clock command or hard-coded Australian zone")
check("layer=overlay" in read("/etc/4tw/mako.conf") and "default-timeout=5000" in read("/etc/4tw/mako.conf"), "notification sits above fullscreen and automatically expires")
check((root / "usr/share/plymouth/themes/4tw/4TW-OS.png").read_bytes() == (project / "assets/4TW-OS.png").read_bytes(), "Plymouth logo is byte-identical to existing asset")
check("Math.Min" in read("/usr/share/plymouth/themes/4tw/4tw.script"), "Plymouth preserves image aspect ratio")
check("Storage=volatile" in read("/etc/systemd/journald.conf.d/4tw.conf"), "logs kept in RAM")
logind = read("/etc/systemd/logind.conf.d/4tw.conf")
check("HandlePowerKey=poweroff" in logind, "physical power button requests clean poweroff")
check("HandleSuspendKey=ignore" in logind and "HandleHibernateKey=ignore" in logind and
      "HandleLidSwitch=ignore" in logind,
      "the appliance exposes no normal logind suspend/hibernate path")
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
               "/usr/local/libexec/4tw-timezone-auto", "/usr/local/libexec/4tw-typewriter",
               "/usr/local/libexec/4tw-online", "/usr/local/sbin/4tw-retry-wifi",
               "/usr/local/sbin/4tw-enter-offline"):
    check("len(sys.argv) != 1" in read(helper), helper + " rejects all arguments")
keyboard_helper = read("/usr/local/sbin/4tw-keyboard-backlight")
keyboard_ui = read("/usr/local/bin/4tw-keyboard-brightness")
keyboard_helper_tree = ast.parse(keyboard_helper)
keyboard_calls = [node for node in ast.walk(keyboard_helper_tree) if isinstance(node, ast.Call) and
                  isinstance(node.func, ast.Name) and node.func.id == "set_keyboard_backlight"]
check('{"up", "down", "off", "status"}' in keyboard_helper and "shell=True" not in keyboard_helper + keyboard_ui and
      len(keyboard_calls) == 1 and len(keyboard_calls[0].args) == 1 and not keyboard_calls[0].keywords and
      "pathlib" not in keyboard_helper.lower() and "Path(" not in keyboard_helper,
      "keyboard helper accepts only fixed actions and no user-selected path or shell command")
package_source = (project / "config/packages.txt").read_text().lower()
check(not any(name in package_source for name in ("linuwu", "acersense", "nitrosense", "acer-gaming")),
      "no third-party Acer control package is requested")
passwd = {line.split(":")[0]: line.split(":") for line in read("/etc/passwd").splitlines()}
check(passwd["kiosk"][-1] == "/usr/local/libexec/4tw-session", "kiosk login program is not a normal shell")
installed = set(subprocess.check_output(["chroot", str(root), "dpkg-query", "-W", "-f=${Package}\n"], text=True).splitlines())
for package in ("openssh-server", "dropbear", "xterm", "foot", "gnome-terminal", "konsole", "nautilus", "thunar", "dolphin", "swaybar", "wofi", "rofi", "gdm3", "sddm", "lightdm", "snapd",
                "cups", "cups-daemon", "avahi-daemon", "bluez", "modemmanager", "packagekit", "power-profiles-daemon", "whoopsie",
                "geoclue-2.0", "libtimezonemap1", "libtimezonemap-data"):
    check(package not in installed, package + " is not installed")
check("chrony" in installed and "tzdata" in installed, "lightweight NTP and installed IANA timezone data are present")
check("focuswriter" in installed and "qt6-wayland" in installed, "Ubuntu FocusWriter and native Qt Wayland support are installed")
check((root / "usr/bin/swaynag").is_file(), "lightweight fixed-purpose Sway prompt is installed")
check(not any(p.startswith("nvidia-driver-") for p in installed), "no proprietary high-power NVIDIA driver setup")
print("Root filesystem checks passed.")
