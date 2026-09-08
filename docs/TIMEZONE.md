# UTC clock and travel-aware timezone

4TW-OS treats the Acer's hardware RTC as UTC at all times. It does not use a fixed offset or rewrite the RTC as local wall-clock time when travelling. Chrony remains the lightweight Ubuntu network-time client, and its `rtcsync` setting maintains normal Linux UTC RTC semantics. Firefox inherits the system IANA timezone; it has no separate timezone spoofing.

## Configuration and startup

The Windows-readable `4TW-CONFIG/4tw.cfg` accepts either:

```text
timezone=auto
timezone=Australia/Darwin
```

`auto` is the default. At boot, `/usr/local/lib/4tw/appliance.py` validates and immediately applies `/var/lib/4tw/timezone`, the last successful automatic result. A new image with no state uses `Etc/UTC`. Firefox and Sway are not ordered after network or location detection.

When NetworkManager reports connectivity, `4tw-timezone-auto.service` gets a short opportunity for chrony to synchronize and then makes at most one provider request in that boot. A volatile `/run/4tw/timezone-attempted` marker prevents repeat requests. Success is accepted only when the response names an installed file under `/usr/share/zoneinfo`. The system timezone and last-known file change only for a validated result, and the state file is not rewritten when its value is unchanged.

A valid manual IANA name is applied directly from installed `tzdata`. It wins over automatic detection, so the provider is never contacted. Invalid or unsafe timezone text cannot become a command or filesystem path and falls back to automatic mode. Change `4tw.cfg` back to `timezone=auto` to resume detection; no IMG rebuild is required.

## Online provider and privacy

The replaceable provider definition is `/etc/4tw/timezone-provider.json`; the current endpoint is:

```text
https://ipapi.co/timezone/
```

This is a single-field HTTPS endpoint inferred from the connection's public IP. The request has no query parameters or body; it sends the normal destination/path and TLS/network metadata plus `Accept: text/plain` and the generic `User-Agent: 4TW-OS-Timezone/1`. The request necessarily reveals that public IP to ipapi.co. 4TW-OS sends no Wi-Fi credentials, account identifier, browser profile, 4thewords data, writing content, GPS coordinates or persistent device identifier. It rejects redirects, JSON/HTML/oversized/multi-line or invalid UTF-8 responses, keeps normal TLS certificate verification, and has a four-second network timeout. Only a validated IANA timezone string is persisted.

Public-IP location is approximate. A VPN, proxy, mobile carrier gateway, hotel network or remote connection can report the wrong region. Use a manual IANA override in those situations. No GeoClue service, Mozilla Location Service, browser location permission or third-party GPS/Wi-Fi scanning component is installed for this feature.

If connectivity, chrony, the provider, validation or timezone application fails, kiosk startup and shutdown continue, RTC semantics remain UTC, and the previous valid timezone remains in place. The service does not retry in a tight loop.

## Runtime files

| Responsibility | File or setting |
| --- | --- |
| UTC RTC policy | `/etc/adjtime` ends in `UTC`; `/etc/localtime` initially links to `Etc/UTC` |
| Network time | `chrony.service`; `/etc/chrony/chrony.conf` contains `rtcsync` |
| Config parser and state logic | `/usr/local/lib/4tw/appliance.py` |
| Online provider module | `/usr/local/lib/4tw/timezone_provider.py` |
| Provider configuration | `/etc/4tw/timezone-provider.json` |
| Bounded automatic service | `/etc/systemd/system/4tw-timezone-auto.service` |
| Connectivity trigger | `/etc/NetworkManager/dispatcher.d/50-4tw-timezone` |
| Current boot mode/attempt | `/run/4tw/timezone-mode`, `/run/4tw/timezone-attempted` |
| Last successful automatic zone | `/var/lib/4tw/timezone` |
| User override | `4TW-CONFIG/4tw.cfg` |

## Windows 11 coexistence

Configure Windows once to interpret the same hardware RTC as UTC. As an administrator, create:

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
RealTimeIsUniversal = DWORD (32-bit) value 1
```

This is a manual Windows-side action. 4TW-OS never attempts it and does not mount or modify the Windows filesystem, registry, EFI partition, BitLocker, TPM, Secure Boot configuration or internal SSD. Windows and Linux still choose their displayed timezone independently.

## Physical hardware checklist

These checks must be performed on the Acer and are not implied by static or VM verification.

Test A — Darwin:

1. Set `timezone=auto` in `4tw.cfg` and boot in Darwin.
2. Confirm network time becomes synchronized and local/browser time resolves to `Australia/Darwin`.
3. Shut down cleanly, boot Windows, and confirm Windows time is immediately correct without toggling automatic time.

Test B — manual override:

1. Set `timezone=Australia/Adelaide` in `4tw.cfg` and boot.
2. Confirm Adelaide's IANA daylight-saving rules apply and no provider request is expected.
3. Restore `timezone=auto` afterward.

Test C — travel:

1. In another state, boot with `timezone=auto`.
2. Confirm the newly detected IANA zone and browser local time are correct.
3. Confirm both operating systems continue to use UTC RTC semantics.
