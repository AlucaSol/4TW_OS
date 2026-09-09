#!/usr/bin/python3
"""Fail when active target configuration reintroduces physical RTC writes."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)
    print("PASS: " + message)


def active_lines(path):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return []
    return [line.split("#", 1)[0].strip() for line in text.splitlines()
            if line.split("#", 1)[0].strip()]


chrony_root = root / "etc/chrony"
chrony_files = [chrony_root / "chrony.conf"]
chrony_files.extend(path for path in (chrony_root / "conf.d").glob("*.conf") if path.is_file())
chrony_files.extend(path for path in (chrony_root / "sources.d").glob("*.sources") if path.is_file())
chrony_active = [(path, line) for path in chrony_files for line in active_lines(path)]
rtc_directives = {"rtcsync", "rtcfile", "rtcautotrim"}
bad_chrony = [(path, line) for path, line in chrony_active
              if line.split(None, 1)[0].lower() in rtc_directives]
check(not bad_chrony, "active chrony configuration has no RTC synchronization/calibration directive")
check(any(line.split(None, 1)[0].lower() in {"pool", "server", "sourcedir"}
          for _path, line in chrony_active), "chrony retains network time sources")
check(any(line.split(None, 1)[0].lower() == "makestep" for _path, line in chrony_active),
      "chrony retains system-clock makestep policy")
check((root / "etc/systemd/system/multi-user.target.wants/chrony.service").is_symlink(),
      "chrony remains enabled for Online system-clock synchronization")

dropin = active_lines(root / "etc/systemd/system/chrony.service.d/4tw-no-rtc.conf")
check("DevicePolicy=closed" in dropin and "DeviceAllow=" in dropin,
      "chronyd's inherited physical-RTC device allowance is reset")

for unit in ("hwclock.service", "hwclock-save.service", "systemd-hwclock-save.service"):
    path = root / "etc/systemd/system" / unit
    check(path.is_symlink() and path.readlink() == Path("/dev/null"), unit + " is explicitly masked")

runtime_roots = (
    root / "usr/local",
    root / "etc/systemd/system",
    root / "etc/init.d",
    root / "etc/NetworkManager",
    root / "usr/lib/systemd/system-shutdown",
)
runtime_files = []
for runtime_root in runtime_roots:
    if runtime_root.exists():
        runtime_files.extend(path for path in runtime_root.rglob("*") if path.is_file())
chrony_unit = root / "usr/lib/systemd/system/chrony.service"
if chrony_unit.is_file():
    runtime_files.append(chrony_unit)

prohibited = (
    re.compile(r"\bhwclock\b", re.IGNORECASE),
    re.compile(r"\bchronyc\b[^\n]*\b(?:writertc|trimrtc)\b", re.IGNORECASE),
    re.compile(r"\btimedatectl\b[^\n]*\b(?:set-time|set-local-rtc)\b", re.IGNORECASE),
    re.compile(r"\bRTC_SET_TIME\b"),
    re.compile(r"/dev/rtc(?:[0-9*]*)?", re.IGNORECASE),
)
violations = []
for path in runtime_files:
    for line in active_lines(path):
        if any(pattern.search(line) for pattern in prohibited):
            violations.append((path.relative_to(root), line))
check(not violations, "active runtime, shutdown and custom service paths contain no known RTC writer")
etc_chrony_units = [path for path in (root / "etc/systemd/system").rglob("*.conf") if path.is_file()]
check(not any(re.search(r"^DeviceAllow\s*=\s*char-rtc\b", line, re.IGNORECASE)
              for path in etc_chrony_units for line in active_lines(path)),
      "no target systemd override re-allows chronyd physical-RTC access")

check(not (root / "etc/adjtime").exists(),
      "no persistent local-RTC or Linux RTC-maintenance state is installed")
rtc_source = (root / "usr/local/lib/4tw/rtc_clock.py").read_text(encoding="utf-8")
check('Path("/sys/class/rtc")' in rtc_source and ".read_text(" in rtc_source and
      "clock_settime" in rtc_source and "/dev/rtc" not in rtc_source and "subprocess" not in rtc_source,
      "boot helper reads RTC sysfs and sets only Linux CLOCK_REALTIME")
appliance = (root / "usr/local/lib/4tw/appliance.py").read_text(encoding="utf-8")
configure = appliance[appliance.index("def configure_runtime()") :]
check(configure.index("prepare_timezone(") < configure.index("import_local_rtc(") < configure.index('if mode == "offline"'),
      "manual/last-known timezone is selected before the one-way RTC import in both modes")
timezone_apply = appliance[appliance.index("def apply_timezone(") : appliance.index("def read_last_known(")]
check("timedatectl" not in timezone_apply and "subprocess" not in timezone_apply and
      "symlink_to(target)" in timezone_apply,
      "timezone changes update zoneinfo presentation files without a clock-management command")

print("RTC no-write policy checks passed.")
