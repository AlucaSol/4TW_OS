# Windows-owned RTC and travel-aware timezone

The Acer's physical hardware clock belongs to Windows and contains Windows local wall-clock time. 4TW-OS may read that clock during startup, but it never updates, trims or synchronises it. While Online is running, Chrony obtains network time and corrects only the Linux system clock. Firefox inherits the selected system IANA timezone; it has no separate timezone spoofing.

## Startup and timezone selection

The Windows-readable `4TW-CONFIG/4tw.cfg` accepts either:

```text
timezone=auto
timezone=Australia/Darwin
```

`auto` is the default. `/usr/local/lib/4tw/appliance.py` first applies the last successful automatic zone from `/var/lib/4tw/timezone`, or `Etc/UTC` when no state exists. A valid manual IANA name wins and bypasses automatic lookup. Values are accepted only when they resolve to an installed regular file under `/usr/share/zoneinfo`; configuration text is never executed.

After that presentation timezone is selected, `/usr/local/lib/4tw/rtc_clock.py` reads only `/sys/class/rtc/rtc*/date` and `/sys/class/rtc/rtc*/time`. It interprets those fields as local wall-clock time in the selected zone and sets only Linux `CLOCK_REALTIME`. It does not open `/dev/rtc`, invoke a hardware-clock utility or expose a system-to-RTC operation. A missing, malformed or implausible RTC value is non-fatal.

Online then proceeds with bounded Wi-Fi startup. When NetworkManager reports connectivity, `4tw-timezone-auto.service` gives Chrony a short opportunity to correct the Linux system clock, then performs at most one automatic timezone request in that boot. A successful changed result updates `/etc/localtime`, `/etc/timezone` and the last-known state; it never changes the Linux system-clock value or the physical RTC merely because the timezone changed.

Offline skips NetworkManager, Chrony and online timezone lookup. It still selects manual/last-known/UTC and performs the same read-only RTC import before FocusWriter starts. If the laptop has travelled and boots Offline before 4TW-OS learns the new timezone, local display and converted timestamps can temporarily use the previous zone. A fresh Offline boot with no last-known location falls back to `Etc/UTC`. Around an ambiguous daylight-saving fall-back hour, a local-only RTC cannot distinguish the two occurrences; Online network time corrects that inherent ambiguity.

## No-write controls

- The build removes active `rtcsync`, `rtcfile` and `rtcautotrim` directives from `/etc/chrony/`. Network source and `makestep` policy remain.
- `/etc/systemd/system/chrony.service.d/4tw-no-rtc.conf` resets Chrony's inherited RTC device allowance while preserving network time.
- `hwclock.service`, `hwclock-save.service` and `systemd-hwclock-save.service` are explicitly masked under `/etc/systemd/system/`.
- `/etc/adjtime` is absent. 4TW-OS does not persist systemd/hwclock local-RTC ownership or maintenance state.
- Timezone changes atomically select an installed zoneinfo file directly; they do not invoke `timedatectl`, `hwclock` or another clock-management command.
- `tests/check-rtc-policy.py` scans the configured runtime and shutdown paths for active RTC writers during every configure and IMG verification pass.

These choices also apply to clean poweroff and the existing Ctrl+Alt+Delete and physical-power-button paths. The kiosk has no suspend shortcut, already ignores lid close, and now explicitly ignores logind suspend/hibernate keys; no normal appliance suspend/resume path is configured.

## Automatic provider and privacy

The fixed provider definition remains `/etc/4tw/timezone-provider.json`:

```text
https://ipapi.co/timezone/
```

This single-field HTTPS endpoint infers a zone from the connection's public IP. It receives normal network/TLS metadata and a generic `4TW-OS-Timezone/1` user agent, but no Wi-Fi credentials, account identifier, browser profile, 4thewords data, writing content, GPS coordinates or persistent device identifier. Redirects, JSON/HTML, oversized or multi-line responses and invalid UTF-8 fail closed. TLS verification remains enabled and the network timeout is four seconds.

Public-IP location can be wrong behind a VPN, proxy, hotel network or carrier gateway. Use a manual IANA override in those cases. No GeoClue, GPS/Wi-Fi-scanning component or Firefox location permission is added. Lookup failure does not block kiosk startup or shutdown, and the service does not retry in a tight loop.

## Runtime files

| Responsibility | File or setting |
| --- | --- |
| Boot-time RTC read | `/usr/local/lib/4tw/rtc_clock.py`, invoked by `4tw-configure.service` after timezone selection |
| RTC maintenance state | `/etc/adjtime` deliberately absent |
| Chrony network sync | enabled `chrony.service`; `/etc/chrony/chrony.conf` retains network sources and `makestep` but no active RTC directive |
| Chrony RTC-device denial | `/etc/systemd/system/chrony.service.d/4tw-no-rtc.conf` |
| RTC-save masks | `/etc/systemd/system/{hwclock,hwclock-save,systemd-hwclock-save}.service` -> `/dev/null` |
| Config, zoneinfo application and last-known logic | `/usr/local/lib/4tw/appliance.py` |
| Online provider module/config | `/usr/local/lib/4tw/timezone_provider.py`; `/etc/4tw/timezone-provider.json` |
| Bounded automatic service/trigger | `/etc/systemd/system/4tw-timezone-auto.service`; `/etc/NetworkManager/dispatcher.d/50-4tw-timezone` |
| Current boot mode/attempt | `/run/4tw/timezone-mode`; `/run/4tw/timezone-attempted` |
| Last successful automatic zone | `/var/lib/4tw/timezone` |
| User override | `timezone=` in `4TW-CONFIG/4tw.cfg` |
| Regression audit | `tests/check-rtc-policy.py` |

## Windows 11 coexistence

Windows should use its normal local-RTC convention. The manually added `RealTimeIsUniversal` value must be removed outside 4TW-OS; **do not set it to `1` for this design**. Leave Windows **Set time automatically** enabled and synchronise Windows once after removing the value.

4TW-OS never mounts or modifies Windows, its registry, EFI partition, BitLocker, TPM, Secure Boot settings, firmware clock settings or internal SSD.

## Deferred physical Acer checklist

The combined IMG has now been built and statically verified. These checks still
require that current image to be flashed and booted on the Acer; they are not
proven by WSL/static verification.

Test A - establish the Windows baseline:

1. Remove `RealTimeIsUniversal` and confirm it is absent with `reg query HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal`.
2. Leave **Set time automatically** on, synchronise once, and shut down normally.
3. Record `Get-Date -Format o`, `Get-TimeZone`, and `w32tm /query /status` in PowerShell. These record Windows' interpreted system-time baseline; Windows does not provide a simple supported command that independently proves the raw RTC contents.

Test B - Online 4TW:

1. Set `timezone=auto`, boot 4TW-OS, and confirm the initial clock is plausible.
2. Connect Wi-Fi and confirm the local/browser zone and time become correct.
3. Leave Online running for at least 15 minutes, then shut down cleanly.
4. Boot Windows and confirm the correct local time appears immediately without toggling automatic time.

Test C - repeat:

1. Repeat the Windows -> 4TW Online -> Windows cycle at least twice.
2. Compare the Windows records and confirm no repeatable offset is introduced.

Test D - Offline:

1. Boot Offline Typewriter without internet using a known manual or last-known zone.
2. Confirm its displayed time is plausible, shut down, and boot Windows.
3. Confirm Windows still starts with the correct local time.

Test E - travel/manual override:

1. In another state, confirm `timezone=auto` learns the new IANA zone when Online.
2. Separately test a valid manual zone such as `Australia/Adelaide`, including its installed DST rules, then restore `timezone=auto`.
3. Do not infer RTC preservation solely from displayed local time; complete the Windows-before/after cycle above.
