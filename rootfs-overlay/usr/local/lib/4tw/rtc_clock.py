"""Import a Windows-owned local hardware clock into the Linux system clock.

The RTC is read only through sysfs.  This module deliberately has no RTC
device access and no system-to-RTC operation.
"""
from datetime import datetime
from pathlib import Path
import re
import time
from zoneinfo import ZoneInfo

SYS_RTC = Path("/sys/class/rtc")
LOCALTIME = Path("/etc/localtime")
_RTC_NAME = re.compile(r"rtc[0-9]+")
_EARLIEST_YEAR = 2020
_LATEST_YEAR = 2099


def _read_attribute(path):
    return path.read_text(encoding="ascii").strip()


def read_local_rtc(rtc_root=SYS_RTC, reader=_read_attribute):
    """Return a plausible naive RTC wall-clock value, or None.

    Reading the date on both sides of the time avoids combining values across
    midnight.  No file beneath sysfs is ever opened for writing.
    """
    try:
        devices = sorted(
            (path for path in rtc_root.glob("rtc[0-9]*") if _RTC_NAME.fullmatch(path.name)),
            key=lambda path: path.name,
        )
    except OSError:
        return None
    for device in devices:
        for _attempt in range(3):
            try:
                date_before = reader(device / "date")
                clock = reader(device / "time")
                date_after = reader(device / "date")
            except (OSError, UnicodeError):
                break
            if date_before != date_after:
                continue
            try:
                wall_clock = datetime.strptime(date_before + " " + clock, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                break
            if _EARLIEST_YEAR <= wall_clock.year <= _LATEST_YEAR:
                return wall_clock
            break
    return None


def local_wallclock_epoch(wall_clock, localtime=LOCALTIME, zone=None):
    """Interpret a naive wall clock using the already-selected IANA timezone."""
    if wall_clock.tzinfo is not None:
        raise ValueError("RTC wall clock must be naive")
    if zone is None:
        with localtime.open("rb") as zone_file:
            zone = ZoneInfo.from_file(zone_file)
    return wall_clock.replace(tzinfo=zone).timestamp()


def import_local_rtc(rtc_root=SYS_RTC, localtime=LOCALTIME, setter=None, clock_id=None):
    """Set only CLOCK_REALTIME from the local RTC; never update the RTC."""
    wall_clock = read_local_rtc(rtc_root)
    if wall_clock is None:
        return "rtc-unavailable"
    try:
        epoch = local_wallclock_epoch(wall_clock, localtime)
    except (OSError, ValueError, OverflowError):
        return "timezone-unavailable"
    setter = setter if setter is not None else getattr(time, "clock_settime", None)
    clock_id = clock_id if clock_id is not None else getattr(time, "CLOCK_REALTIME", None)
    if setter is None or clock_id is None:
        return "system-clock-unavailable"
    try:
        setter(clock_id, epoch)
    except (OSError, ValueError, OverflowError):
        return "system-clock-update-failed"
    return "system-clock-initialized"
