"""Fixed-purpose kiosk helpers. No config values are evaluated as code."""
import base64
import binascii
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time
from urllib.parse import urlsplit

DEFAULT_URL = "https://4thewords.com/"
ZONEINFO = Path("/usr/share/zoneinfo")
LOCALTIME = Path("/etc/localtime")
TIMEZONE_FILE = Path("/etc/timezone")
TIMEZONE_STATE = Path("/var/lib/4tw/timezone")
TIMEZONE_MODE = Path("/run/4tw/timezone-mode")
TIMEZONE_ATTEMPTED = Path("/run/4tw/timezone-attempted")
APPLIANCE_MODE = Path("/run/4tw/mode")
WIFI_STATUS = Path("/run/4tw/wifi-status")
WRITING_STATUS = Path("/run/4tw/writing-status")
WRITING_ROOT = Path("/writing")
NETWORK_CONNECTION = Path("/run/NetworkManager/system-connections/4tw-wifi.nmconnection")
NETWORK_UUID = "2d5b597a-e4aa-4499-8b09-7ba9ec67508d"
UTC_ZONE = "Etc/UTC"
SYS_POWER = Path("/sys/class/power_supply")
SYS_BACKLIGHT = Path("/sys/class/backlight")
SYS_PCI = Path("/sys/bus/pci/devices")
SYS_DRM = Path("/sys/class/drm")
DEV_DRI = Path("/dev/dri")
SYS_CPU = Path("/sys/devices/system/cpu")
SYS_USB = Path("/sys/bus/usb/devices")
NVIDIA_VENDOR = "0x10de"


def number(path):
    try:
        value = float(path.read_text().strip())
        return value if math.isfinite(value) and value >= 0 else None
    except (OSError, ValueError):
        return None


def battery_text(root=SYS_POWER):
    sections = []
    for bat in sorted(root.glob("BAT*")):
        if number(bat / "present") == 0:
            continue
        lines = []
        capacity = number(bat / "capacity")
        if capacity is not None and capacity <= 100:
            lines.append(f"Battery: {capacity:.0f}%")
        try:
            status = (bat / "status").read_text().strip()
        except OSError:
            status = ""
        if status in {"Charging", "Discharging", "Full", "Not charging", "Unknown"}:
            lines.append(f"Status: {status}")
        power = number(bat / "power_now")
        current = number(bat / "current_now")
        voltage = number(bat / "voltage_now")
        if power is not None:
            watts = power / 1_000_000
        elif current is not None and voltage is not None and voltage > 0:
            watts = current * voltage / 1_000_000_000_000
        else:
            watts = None
        if watts is not None:
            lines.append(f"Power draw: {watts:.1f} W")
        # Runtime means time until empty, not time until fully charged.
        hours = None
        if status == "Discharging":
            energy = number(bat / "energy_now")
            charge = number(bat / "charge_now")
            # Use matched energy/power or charge/current units; do not use
            # instantaneous voltage to invent an energy conversion.
            if energy is not None and power is not None and power > 0:
                hours = energy / power
            elif charge is not None and current is not None and current > 0:
                hours = charge / current
            else:
                seconds = number(bat / "time_to_empty_now")
                if seconds is not None and 0 < seconds < 604800:
                    hours = seconds / 3600
        if hours is not None and math.isfinite(hours) and 0 <= hours < 168:
            minutes = round(hours * 60)
            lines.append(f"Estimated remaining: ~{minutes // 60}h {minutes % 60}m")
        if not lines:
            lines = ["Battery information unavailable"]
        if len(list(root.glob("BAT*"))) > 1:
            lines.insert(0, bat.name)
        sections.append("\n".join(lines))
    return "\n\n".join(sections) or "Battery information unavailable"


def discrete_gpu_status(root=SYS_PCI):
    """Return a conservative NVIDIA display-device runtime-PM state."""
    states = []
    try:
        devices = sorted(root.iterdir())
    except OSError:
        devices = []
    for device in devices:
        try:
            vendor = (device / "vendor").read_text().strip().lower()
            device_class = (device / "class").read_text().strip().lower()
        except OSError:
            continue
        if vendor != NVIDIA_VENDOR or not device_class.startswith("0x03"):
            continue
        try:
            states.append((device / "power/runtime_status").read_text().strip().lower())
        except OSError:
            states.append("")
    if any(state in {"active", "resuming"} for state in states):
        return "active"
    if states and all(state == "suspended" for state in states):
        return "suspended"
    return "unavailable"


def battery_overlay_text(power_root=SYS_POWER, pci_root=SYS_PCI):
    return battery_text(power_root) + "\n" + f"dGPU: {discrete_gpu_status(pci_root)}"


def _drm_cards(drm_root, dev_root):
    cards = []
    try:
        candidates = sorted(drm_root.glob("card[0-9]*"), key=lambda path: path.name)
    except OSError:
        return cards
    for card in candidates:
        if not re.fullmatch(r"card[0-9]+", card.name) or not (card / "device").exists():
            continue
        device_node = dev_root / card.name
        if device_node.exists():
            cards.append((card, device_node))
    return cards


def preferred_drm_device(drm_root=SYS_DRM, dev_root=DEV_DRI):
    """Choose a card only when the internal-panel mapping is unambiguous."""
    cards = _drm_cards(drm_root, dev_root)
    by_name = {card.name: (card, node) for card, node in cards}
    internal = []
    for connector in sorted(drm_root.glob("card*-*"), key=lambda path: path.name):
        match = re.fullmatch(r"(card[0-9]+)-(eDP|LVDS|DSI)-.+", connector.name)
        if not match or match.group(1) not in by_name:
            continue
        try:
            connected = (connector / "status").read_text().strip() == "connected"
        except OSError:
            connected = False
        if connected:
            internal.append(by_name[match.group(1)])
    if internal:
        # A non-NVIDIA card driving the internal panel is the normal iGPU.
        # If only NVIDIA drives that panel, it is genuinely required.
        def nvidia_first_key(item):
            try:
                is_nvidia = (item[0] / "device/vendor").read_text().strip().lower() == NVIDIA_VENDOR
            except OSError:
                is_nvidia = True
            return is_nvidia, item[0].name
        internal.sort(key=nvidia_first_key)
        return str(internal[0][1])
    if len(cards) == 1:
        return str(cards[0][1])
    # With multiple GPUs and no connected internal connector, let wlroots
    # detect the usable topology instead of guessing from a PCI address.
    return None


def integrated_drm_device(drm_root=SYS_DRM, dev_root=DEV_DRI):
    selected = preferred_drm_device(drm_root, dev_root)
    if not selected:
        return None
    card = drm_root / Path(selected).name
    try:
        vendor = (card / "device/vendor").read_text().strip().lower()
    except OSError:
        return None
    return selected if vendor != NVIDIA_VENDOR else None


def _write_sysfs(path, value):
    try:
        if path.read_text().strip() != value:
            path.write_text(value)
        return True
    except OSError:
        return False


def _usb_is_protected(device):
    """Keep storage, keyboards/input and networking out of our autosuspend pass."""
    try:
        for interface in device.parent.glob(device.name + ":*"):
            try:
                interface_class = (interface / "bInterfaceClass").read_text().strip().lower()
            except OSError:
                continue
            if interface_class in {"03", "08"}:  # HID or mass storage
                return True
        for descendant in device.rglob("*"):
            if descendant.name in {"block", "input", "net"}:
                return True
    except OSError:
        return True
    return False


def apply_power_policy(pci_root=SYS_PCI, cpu_root=SYS_CPU, usb_root=SYS_USB):
    """Apply bounded, normal runtime-PM settings; never force devices off."""
    applied = {"nvidia": 0, "cpu": 0, "usb": 0}
    nvidia_functions = set()
    try:
        pci_devices = sorted(pci_root.iterdir())
    except OSError:
        pci_devices = []
    for device in pci_devices:
        try:
            vendor = (device / "vendor").read_text().strip().lower()
            device_class = (device / "class").read_text().strip().lower()
        except OSError:
            continue
        if vendor == NVIDIA_VENDOR and device_class.startswith("0x03"):
            slot = device.name.rsplit(".", 1)[0]
            for function in pci_root.glob(slot + ".*"):
                try:
                    if (function / "vendor").read_text().strip().lower() == NVIDIA_VENDOR:
                        nvidia_functions.add(function)
                except OSError:
                    continue
    for function in sorted(nvidia_functions):
        if _write_sysfs(function / "power/control", "auto"):
            applied["nvidia"] += 1

    policies = []
    try:
        policies.extend((cpu_root / "cpufreq").glob("policy*"))
        if not policies:
            policies.extend(cpu_root.glob("cpu[0-9]*/cpufreq"))
    except OSError:
        policies = []
    seen = set()
    for policy in policies:
        resolved = str(policy.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        changed = False
        try:
            preferences = (policy / "energy_performance_available_preferences").read_text().split()
        except OSError:
            preferences = []
        if "balance_power" in preferences:
            changed |= _write_sysfs(policy / "energy_performance_preference", "balance_power")
        try:
            driver = (policy / "scaling_driver").read_text().strip()
            governors = (policy / "scaling_available_governors").read_text().split()
        except OSError:
            driver, governors = "", []
        if driver in {"amd-pstate", "amd-pstate-epp", "intel_pstate"} and "powersave" in governors:
            changed |= _write_sysfs(policy / "scaling_governor", "powersave")
        if changed:
            applied["cpu"] += 1

    try:
        usb_devices = sorted(usb_root.iterdir())
    except OSError:
        usb_devices = []
    for device in usb_devices:
        if not (device / "idVendor").exists() or _usb_is_protected(device):
            continue
        if _write_sysfs(device / "power/control", "auto"):
            _write_sysfs(device / "power/autosuspend_delay_ms", "2000")
            applied["usb"] += 1
    return applied


def _cpu_values(cpu_root, filename):
    values = set()
    for path in (cpu_root / "cpufreq").glob("policy*/" + filename):
        try:
            value = path.read_text().strip()
        except OSError:
            continue
        if value:
            values.add(value)
    return ", ".join(sorted(values)) or "unavailable"


def _firefox_cpu_percent(proc_root=Path("/proc"), sample_seconds=0.2):
    def snapshot():
        try:
            total = sum(int(value) for value in (proc_root / "stat").read_text().splitlines()[0].split()[1:])
        except (OSError, ValueError, IndexError):
            return None
        firefox = 0
        for process in proc_root.glob("[0-9]*"):
            try:
                command = (process / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                stat = (process / "stat").read_text()
                fields = stat[stat.rfind(")") + 2:].split()
                if "firefox" in command.lower():
                    firefox += int(fields[11]) + int(fields[12])
            except (OSError, ValueError, IndexError):
                continue
        return total, firefox
    first = snapshot()
    if first is None:
        return None
    time.sleep(sample_seconds)
    second = snapshot()
    if second is None or second[1] < first[1] or second[0] <= first[0]:
        return None
    return (second[1] - first[1]) * 100 * (os.cpu_count() or 1) / (second[0] - first[0])


def power_diagnostics():
    lines = [battery_overlay_text()]
    lines.append("Integrated GPU DRM: " + (integrated_drm_device() or "unavailable"))
    lines.append("CPU governor: " + _cpu_values(SYS_CPU, "scaling_governor"))
    lines.append("CPU energy preference: " + _cpu_values(SYS_CPU, "energy_performance_preference"))
    firefox_cpu = _firefox_cpu_percent()
    lines.append("Firefox CPU: " + (f"{firefox_cpu:.1f}%" if firefox_cpu is not None else "unavailable"))
    try:
        lines.append("Load average: " + " ".join(f"{value:.2f}" for value in os.getloadavg()))
    except OSError:
        lines.append("Load average: unavailable")
    try:
        memory = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, _, value = line.partition(":")
            if key in {"MemTotal", "MemAvailable"}:
                memory[key] = int(value.split()[0])
        used = memory["MemTotal"] - memory["MemAvailable"]
        lines.append(f"Memory: {used // 1024} MiB used / {memory['MemTotal'] // 1024} MiB total")
    except (OSError, ValueError, KeyError, IndexError):
        lines.append("Memory: unavailable")
    return "\n".join(lines)


def notify(body):
    subprocess.run([
        "/usr/bin/notify-send", "--app-name=4TW-OS", "--expire-time=5000",
        "--hint=string:x-canonical-private-synchronous:4tw-status",
        "--", "4TW-OS", body,
    ], check=False, timeout=5)


def backlight_target(current, maximum, action):
    if action not in {"up", "down", "default"} or maximum < 1:
        raise ValueError("Invalid backlight request")
    maximum = int(maximum)
    percent = 50 if action == "default" else round(current * 100 / maximum) + (10 if action == "up" else -10)
    percent = min(100, max(10, percent))
    value = min(maximum, max(math.ceil(maximum / 10), round(maximum * percent / 100)))
    return value, round(value * 100 / maximum)


def set_backlight(action, root=SYS_BACKLIGHT):
    if action not in {"up", "down", "default"}:
        raise ValueError("Invalid backlight request")
    devices = []
    for device in root.glob("*"):
        maximum = number(device / "max_brightness")
        current = number(device / "brightness")
        if maximum is None or current is None or maximum < 1:
            continue
        try:
            kind = (device / "type").read_text().strip()
        except OSError:
            kind = ""
        devices.append(({"raw": 0, "platform": 1, "firmware": 2}.get(kind, 3), device, current, maximum))
    if not devices:
        return None
    _, device, current, maximum = sorted(devices)[0]
    value, percent = backlight_target(current, maximum, action)
    try:
        (device / "brightness").write_text(str(value))
    except OSError:
        return None
    return percent


def permitted_url(url, patterns):
    if not isinstance(url, str) or len(url) > 4096 or any(ord(c) < 33 or ord(c) == 127 for c in url):
        return False
    try:
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443):
            return False
        host = (parsed.hostname or "").lower()
    except ValueError:
        return False
    for pattern in patterns:
        match = re.fullmatch(r"https://(\*\.)?([a-z0-9]+(?:[.-][a-z0-9]+)*)/\*", pattern)
        if not match:
            raise ValueError("Unsupported allowlist pattern")
        wildcard, domain = match.groups()
        if host == domain or (wildcard and host.endswith("." + domain)):
            return True
    return False


def boot_mode(cmdline):
    """Accept one explicit fixed kernel mode; all malformed input is Online."""
    values = [item.partition("=")[2] for item in cmdline.split() if item.startswith("4tw.mode=")]
    return values[0] if len(values) == 1 and values[0] in {"online", "offline"} else "online"


def _write_runtime(path, value):
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    path.write_text(value + "\n", encoding="utf-8")
    path.chmod(0o644)


def _run_fixed(command, runner=subprocess.run, timeout=10):
    try:
        result = runner(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=timeout, check=False)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def connect_wifi(connection_path=NETWORK_CONNECTION, runner=subprocess.run):
    """Make one bounded attempt using only the builder-created NM keyfile."""
    if not connection_path.is_file():
        return False
    commands = (
        (["/usr/bin/nmcli", "networking", "on"], 5),
        (["/usr/bin/nmcli", "radio", "wifi", "on"], 5),
        (["/usr/bin/nmcli", "connection", "load", str(connection_path)], 5),
        (["/usr/bin/nmcli", "--wait", "12", "connection", "up", "uuid", NETWORK_UUID], 15),
    )
    return all(_run_fixed(command, runner, timeout) for command, timeout in commands)


def _start_network(runner=subprocess.run):
    return _run_fixed(["/usr/bin/systemctl", "start", "NetworkManager.service"], runner, 8)


def _schedule_timezone(runner=subprocess.run):
    _run_fixed(["/usr/bin/systemctl", "--no-block", "start", "4tw-timezone-auto.service"], runner, 3)


def retry_wifi(runner=subprocess.run, connection_path=NETWORK_CONNECTION,
               mode_path=APPLIANCE_MODE, status_path=WIFI_STATUS):
    """Root-only entry point used by one exact sudo rule; accepts no input."""
    try:
        if mode_path.read_text(encoding="utf-8").strip() != "online":
            return False
    except OSError:
        return False
    connected = _start_network(runner) and connect_wifi(connection_path, runner)
    _write_runtime(status_path, "connected" if connected else "failed")
    if connected:
        try:
            automatic = TIMEZONE_MODE.read_text(encoding="utf-8").strip() == "auto"
        except OSError:
            automatic = False
        if automatic:
            _schedule_timezone(runner)
    return connected


def enter_offline(runner=subprocess.run, is_mount=os.path.ismount,
                  mode_path=APPLIANCE_MODE, status_path=WRITING_STATUS):
    """Disable networking for this boot and mount only 4TW-WRITING."""
    _write_runtime(mode_path, "offline")
    # All commands and unit names are fixed; failures never expose a shell.
    for command, timeout in (
        (["/usr/bin/systemctl", "stop", "4tw-timezone-auto.service"], 5),
        (["/usr/bin/nmcli", "networking", "off"], 5),
        (["/usr/bin/nmcli", "radio", "wifi", "off"], 5),
        (["/usr/bin/systemctl", "stop", "NetworkManager.service"], 8),
        (["/usr/bin/systemctl", "stop", "chrony.service"], 5),
        (["/usr/bin/systemctl", "start", "writing.mount"], 12),
    ):
        _run_fixed(command, runner, timeout)
    ready = bool(is_mount(str(WRITING_ROOT)))
    _write_runtime(status_path, "ready" if ready else "failed")
    return ready


def recent_writing_document(root=WRITING_ROOT):
    """Return the most recently modified eligible user .txt file."""
    candidates = []
    try:
        walker = os.walk(root, topdown=True, followlinks=False)
        for folder, directories, files in walker:
            directories[:] = sorted(name for name in directories
                                     if not name.startswith((".", "~")) and
                                     name not in {"System Volume Information", "$RECYCLE.BIN"})
            for name in sorted(files):
                lower = name.lower()
                if (not lower.endswith(".txt") or lower == "readme.txt" or
                        name.startswith((".", "~", ".#", "~$")) or name.endswith("~") or
                        lower.endswith((".tmp.txt", ".temp.txt", ".recovery.txt", ".autosave.txt"))):
                    continue
                path = Path(folder, name)
                try:
                    details = path.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(details.st_mode):
                    candidates.append((details.st_mtime_ns, path.as_posix().casefold(), path))
    except OSError:
        return None
    return max(candidates)[2] if candidates else None


def ensure_writing_document(root=WRITING_ROOT, now=None):
    """Select a recent document or atomically create a persistent empty draft."""
    selected = recent_writing_document(root)
    if selected is not None:
        return selected
    drafts = root / "Drafts"
    drafts.mkdir(mode=0o755, parents=True, exist_ok=True)
    timestamp = (now or datetime.now()).strftime("%Y-%m-%d-%H%M")
    for suffix in ("", *(f"-{number}" for number in range(2, 1000))):
        candidate = drafts / f"Draft-{timestamp}{suffix}.txt"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(candidate, flags, 0o644)
        except FileExistsError:
            continue
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.flush()
            os.fsync(handle.fileno())
        return candidate
    raise OSError("Could not allocate a unique draft filename")


def valid_timezone(value, zoneinfo_root=ZONEINFO):
    """Return a safe installed IANA timezone name, or None."""
    if not isinstance(value, str) or not value or len(value) > 128:
        return None
    if value.startswith(("/", "\\")) or "\\" in value or any(ord(char) < 33 or ord(char) == 127 for char in value):
        return None
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts) or parts[0] in {"posix", "right", "SystemV"}:
        return None
    try:
        root = zoneinfo_root.resolve(strict=True)
        candidate = (root / value).resolve(strict=True)
        candidate.relative_to(root)
        if not candidate.is_file():
            return None
    except (OSError, RuntimeError, ValueError):
        return None
    return value


def current_timezone(localtime=LOCALTIME, zoneinfo_root=ZONEINFO):
    try:
        root = zoneinfo_root.resolve(strict=True)
        selected = localtime.resolve(strict=True)
        value = selected.relative_to(root).as_posix()
    except (OSError, RuntimeError, ValueError):
        return None
    return valid_timezone(value, root)


def apply_timezone(value, zoneinfo_root=ZONEINFO, localtime=LOCALTIME, runner=subprocess.run):
    """Apply a validated timezone through timedated; never changes RTC mode."""
    zone = valid_timezone(value, zoneinfo_root)
    if not zone:
        return False
    if current_timezone(localtime, zoneinfo_root) == zone:
        return True
    try:
        result = runner(
            ["/usr/bin/timedatectl", "set-timezone", zone],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def read_last_known(state_path=TIMEZONE_STATE, zoneinfo_root=ZONEINFO):
    try:
        value = state_path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return valid_timezone(value, zoneinfo_root)


def write_last_known(value, state_path=TIMEZONE_STATE, zoneinfo_root=ZONEINFO):
    """Atomically persist a changed, validated timezone without following links."""
    zone = valid_timezone(value, zoneinfo_root)
    if not zone:
        return False
    if read_last_known(state_path, zoneinfo_root) == zone:
        return True
    temporary = state_path.with_name("." + state_path.name + ".new")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    try:
        state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(temporary, flags, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(zone + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, state_path)
        state_path.chmod(0o600)
        return True
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass
        return False


def prepare_timezone(mode, state_path=TIMEZONE_STATE, zoneinfo_root=ZONEINFO, apply=apply_timezone):
    """Apply a manual zone, or the last automatic zone with UTC fallback."""
    if mode == "auto":
        zone = read_last_known(state_path, zoneinfo_root) or UTC_ZONE
    else:
        zone = valid_timezone(mode, zoneinfo_root) or UTC_ZONE
    return zone, apply(zone, zoneinfo_root=zoneinfo_root)


def automatic_timezone_once(provider, mode_path=TIMEZONE_MODE, attempted_path=TIMEZONE_ATTEMPTED,
                            state_path=TIMEZONE_STATE, zoneinfo_root=ZONEINFO, apply=apply_timezone):
    """Call the fixed provider at most once this boot, and only in auto mode."""
    try:
        if mode_path.read_text(encoding="utf-8").strip() != "auto":
            return "manual-override"
    except OSError:
        return "configuration-unavailable"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(attempted_path, flags, 0o600)
        os.close(fd)
    except FileExistsError:
        return "already-attempted"
    except OSError:
        return "attempt-marker-failed"
    try:
        candidate = provider()
    except Exception:
        # Provider failures are presentation failures and must not affect boot.
        return "lookup-failed"
    zone = valid_timezone(candidate, zoneinfo_root)
    if not zone:
        return "lookup-failed"
    if not apply(zone, zoneinfo_root=zoneinfo_root):
        return "apply-failed"
    if not write_last_known(zone, state_path, zoneinfo_root):
        return "state-write-failed"
    return "updated"


def parse_config(text, patterns, zoneinfo_root=ZONEINFO):
    if len(text.encode("utf-8")) > 16384:
        raise ValueError("Configuration too large")
    values = {}
    for line in text.lstrip("\ufeff").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if not separator or key not in {"wifi_ssid_b64", "wifi_psk_b64", "start_url", "timezone"} or key in values:
            raise ValueError("Unsupported or duplicate configuration key")
        values[key] = value
    url = values.get("start_url") or DEFAULT_URL
    if not permitted_url(url, patterns):
        raise ValueError("Start URL is not allowed")
    try:
        ssid = base64.b64decode(values.get("wifi_ssid_b64", ""), validate=True)
        secret = base64.b64decode(values.get("wifi_psk_b64", ""), validate=True)
        psk = secret.decode("utf-8")
    except (ValueError, UnicodeError, binascii.Error) as error:
        raise ValueError("Invalid Base64 credentials") from error
    if ssid or psk:
        if not 1 <= len(ssid) <= 32:
            raise ValueError("Invalid SSID length")
        if not (8 <= len(secret) <= 63 or re.fullmatch(r"[0-9a-fA-F]{64}", psk)):
            raise ValueError("Invalid Wi-Fi password length")
        if any(ord(c) < 32 or ord(c) == 127 for c in psk):
            raise ValueError("Unsupported control character in Wi-Fi password")
    requested_timezone = values.get("timezone", "auto")
    timezone = requested_timezone if requested_timezone == "auto" else valid_timezone(requested_timezone, zoneinfo_root)
    if not timezone:
        # An invalid manual value cannot be applied; retain normal auto mode.
        timezone = "auto"
    return url, ssid, psk, timezone


def nm_keyfile(ssid, psk):
    # NetworkManager/GLib keyfile escaping; SSID is an explicit byte array.
    escaped = psk.replace("\\", "\\\\").replace(" ", "\\s")
    return (
        "[connection]\nid=4tw-wifi\nuuid=2d5b597a-e4aa-4499-8b09-7ba9ec67508d\n"
        "type=wifi\nautoconnect=true\nautoconnect-retries=2\n\n"
        "[wifi]\nmode=infrastructure\nssid=" + ";".join(str(c) for c in ssid) + ";\n\n"
        "[wifi-security]\nkey-mgmt=wpa-psk\npsk=" + escaped + "\n\n"
        "[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n"
    )


def configure_runtime():
    runtime = Path("/run/4tw")
    runtime.mkdir(mode=0o755, exist_ok=True)
    try:
        mode = boot_mode(Path("/proc/cmdline").read_text(encoding="utf-8"))
    except OSError:
        mode = "online"
    _write_runtime(APPLIANCE_MODE, mode)
    url, ssid, psk, timezone = DEFAULT_URL, b"", "", "auto"
    try:
        patterns = json.loads(Path("/etc/4tw/allowed-sites.json").read_text())
        with Path("/config/4tw.cfg").open(encoding="utf-8-sig") as handle:
            text = handle.read(16385)
        url, ssid, psk, timezone = parse_config(text, patterns)
    except (OSError, ValueError, UnicodeError):
        # Never print the input or a decoder exception containing credentials.
        print("4TW-OS: configuration unavailable or invalid; using safe defaults.", flush=True)
    _write_runtime(runtime / "start-url", url)
    _write_runtime(TIMEZONE_MODE, timezone)
    applied_zone, applied = prepare_timezone(timezone)
    if not applied:
        print("4TW-OS: could not apply timezone " + applied_zone + "; continuing kiosk startup.", flush=True)

    if mode == "offline":
        if not enter_offline():
            print("4TW-OS: writing storage is unavailable; the fixed session prompt will retry.", flush=True)
        return

    _write_runtime(WIFI_STATUS, "failed")
    if not ssid:
        print("4TW-OS: Wi-Fi credentials are not configured.", flush=True)
    else:
        NETWORK_CONNECTION.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(NETWORK_CONNECTION, flags, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(nm_keyfile(ssid, psk))
        connected = _start_network() and connect_wifi()
        _write_runtime(WIFI_STATUS, "connected" if connected else "failed")
        if not connected:
            print("4TW-OS: Wi-Fi did not connect; the fixed session prompt will offer choices.", flush=True)
        elif timezone == "auto":
            _schedule_timezone()
