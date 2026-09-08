# Release verification

The final deliverable is `artifacts/4TW-OS_RELEASE.img` (17,179,869,184 bytes). Use its adjacent `.sha256` file for the definitive final checksum. This report distinguishes automated/VM checks from Acer hardware testing.

Final SHA-256:

```text
4908aa0cf6b36e7ce7fef27a3d907a1cabdfaafd2b584906976723fce9ae35fc
```

## Actual IMG inspection

The image was attached as a **read-only loop device**, not flashed to a drive. `artifacts/verify-img.log` records these checks:

| Check | Result |
| --- | --- |
| GPT, primary/backup tables | Valid; 4 partitions in one 16 GiB image |
| Partition 1 | 256 MiB FAT32, EFI System Partition, `4TW-EFI` |
| Partition 2 | 11,774 MiB ext4, `4TW-ROOT`, about 8.5 GiB free |
| Partition 3 | 256 MiB FAT32, `4TW-CONFIG` |
| Partition 4 | Approximately 4.0 GiB FAT32, `4TW-WRITING` |
| Filesystem checks | ext4 and all three FAT filesystems pass read-only fsck |
| CONFIG writable | A byte-for-byte copy of partition 3 accepts file creation; final IMG remains unmodified by this test |
| WRITING writable | A sparse byte-for-byte copy of partition 4, mounted with production ownership/restrictions, permits kiosk UID 1000 to create and rename files |
| Model/base | `/etc/4tw-release`: `MODEL=Release`; Ubuntu 26.04 amd64 |
| Removable boot path | `EFI/BOOT/BOOTX64.EFI`, accompanying signed GRUB and MokManager |
| Shim | Microsoft Windows UEFI Driver Publisher / Microsoft UEFI CA 2011 signature listed |
| GRUB and kernel | Canonical Secure Boot Signing (2022 v1) signatures listed |
| Boot binary integrity | EFI copies byte-match packaged files; dpkg verification of signed shim/GRUB/kernel packages passes |
| Kernel/initramfs | Correct files exist and GRUB selects the image's exact root UUID |
| Boot menu | Exactly `4TW Online` and `Offline Typewriter`; Online default; visible five-second timeout; exact `4tw.mode=online/offline` parameters |
| Boot default config | GRUB locates `4TW-CONFIG`, reads `4tw-boot.cfg` before the fixed timeout, maps only `offline` to Offline and otherwise falls back Online; both entries remain selectable |
| Boot editing/console | GRUB command/edit access remains password-locked; the two appliance entries are unrestricted for normal selection |
| Logo | Installed PNG byte-matches the original BCLD asset and is present inside initramfs |
| Firefox launch | Online only: one fixed invocation, `--kiosk`, one positional URL, persistent profile, launcher lock |
| Website policy | Native WebsiteFilter blocks all URLs except the explicit HTTPS 4thewords allowlist |
| Sway modes | One shared control-only config plus one fixed Online launcher or one fixed Offline launcher; no generic desktop includes |
| Kiosk controls | The same four fixed global battery, brightness and shutdown commands are present in both modes |
| Privilege scope | Exact poweroff, brightness up/down, Wi-Fi retry and Offline-transition commands; arguments and general sudo commands are rejected |
| Services/applications | No SSH server, terminal emulator, file manager, desktop environment, display manager, Snap daemon or application launcher installed |
| Wi-Fi | NetworkManager is not globally enabled; Online starts it explicitly, restores Wi-Fi and uses a 12-second association bound; Ethernet and wait-online remain disabled |
| Wi-Fi failure | Fixed overlay exposes only Retry Wi-Fi, Offline Typewriter and Shut Down; no terminal/launcher/input field; Retry is asynchronous and the launcher closes the prompt only after root-owned status reports success; Offline is never automatic |
| Offline networking | Mode helper stops automatic timezone lookup, NetworkManager and chrony before mounting WRITING; Offline mode never invokes Firefox |
| FocusWriter | Ubuntu 1.9.0 package and qt6-wayland installed; one document argument; exact native main window forced fullscreen; dialogs not matched by the rule |
| Document flow | Newest eligible `.txt` selected; README/hidden/system/lock/temp/recovery files excluded; otherwise a real timestamped Draft is atomically created |
| FocusWriter storage | Default format `txt`, Save/Open location `/writing/Drafts`, persistent emergency recovery state; Ctrl+S accurately documented as required for normal saves |
| WRITING mount | FAT32 by exact UUID at `/writing`, `noauto,nofail,noexec,nodev,nosuid,uid=1000,gid=1000`; absent from Online mounts |
| Credentials/test data | No Wi-Fi credentials, populated runtime Firefox profile, test profile or automation flags in the image |
| Flash writes | RAM transient directories/logs/cache; no USB swap; normal profile persistence |
| GPU preference | Internal-panel DRM selection is enabled; offload variables are cleared; ambiguous layouts fall back safely |
| NVIDIA runtime PM | Fixed boot helper applies only normal `power/control=auto`; no force-off/removal or proprietary driver |
| CPU policy | `balance_power` EPP and modern pstate `powersave` are selected only when advertised |
| USB autosuspend | Storage, HID/input and networking are explicitly excluded |
| Firefox writes/graphics | RAM cache parent and five-minute recovery interval; persistent profile retained; hardware acceleration not disabled |
| Background work | Package backup, ext4 scrub, MOTD news and Ubuntu Pro units are masked and documented |
| Build cache | No package archives or external build-cache directory in the image |
| RTC policy | `/etc/adjtime` ends in `UTC`; no local-RTC command or `LOCAL` policy is installed |
| Local timezone fallback | `/etc/localtime` links to `/usr/share/zoneinfo/Etc/UTC`; `/etc/timezone` is `Etc/UTC` |
| Network time | Chrony is installed/enabled for Online and retains `rtcsync`; fixed Offline transition stops it without changing UTC RTC semantics |
| Automatic timezone | Connectivity-gated, sandboxed `4tw-timezone-auto.service`, ten-second unit bound and four-second HTTPS provider timeout |
| Location privacy | Single-field `https://ipapi.co/timezone/`; redirects/JSON/HTML/invalid UTF-8/oversized responses rejected; GeoClue is not installed |
| Last-known state | Fresh IMG has no stale `/var/lib/4tw/timezone`; successful changed automatic results can persist there |
| Manual override | `timezone=<validated IANA name>` bypasses the provider; default CONFIG is `timezone=auto` |

`sgdisk` notes that the final partition ends at the last GPT-usable sector rather than a 2048-sector boundary. This is not a filesystem error; no partition encryption tool is used. `sbverify` notes ordinary PE section gaps in packaged shim/MokManager; their signed bytes are unchanged.

## Pre-image runtime tests

`tests/test_helpers.py`: **17 tests passed**, covering capacity-only/missing batteries, power/current conversions, measured-rate runtime estimates, dGPU states, internal-panel GPU selection, conservative NVIDIA/CPU/USB policy, invalid fields, brightness steps/clamps, integer sysfs writes, URL validation, Base64 validation, duplicate/unknown keys, validated timezone configuration and shell-like text treated only as data.

`tests/test_timezone.py`: **8 tests passed**, covering the fixed HTTPS endpoint and four-second timeout, one minimal request, rejected redirects, provider timeout/unavailability, malformed JSON/HTML/multiple lines/invalid UTF-8/oversized responses, installed-zone validation, fixed `timedatectl` argument construction, last-known/UTC startup fallback, unchanged-state write avoidance, invalid-response state preservation, one-attempt-per-boot behaviour, and proof that manual mode never invokes the provider.

`tests/test_dual_mode.py` passed, covering valid and malformed kernel-mode
selection, fixed/bounded NetworkManager commands, Offline service stopping and
WRITING mounting, newest-document selection, exclusion handling, persistent
timestamped Draft creation, exact two-entry GRUB output, safe Online fallback,
CONFIG-before-timeout ordering and GRUB syntax validation.

`tests/test_build_portability.py`: **13 tests passed**, covering explicit,
sudo, WSL-default and unambiguous account selection; rejected root/unknown/
ambiguous users and unsafe or Windows-backed homes; WSL configuration parsing;
source and destination paths containing spaces; byte-identical project-local
logo copying; clear missing-logo failure; silent missing optional cache;
copy-only/ignore-existing `.deb` cache seeding; generated-directory exclusion;
and absence of original-developer paths from source. All build `.sh` files also
passed `bash -n`. These build-host-only tests did not alter the configured
rootfs or final IMG.

`systemd-analyze verify` passed for `4tw-configure.service`, `4tw-timezone-auto.service`, `chrony.service` and `NetworkManager.service` against the configured Ubuntu rootfs (with only the unrelated man-page existence check disabled).

Sway's own validator passed for the shared, Online and Offline configurations.
The installed FocusWriter package was launched under headless Sway with native
Wayland app ID `focuswriter`, exact title `FocusWriter`, and Sway
`fullscreen_mode=1`; its temporary document/settings/recovery data was not
shipped. `visudo` passed. Running `sudo -l` as the kiosk account allowed only
the intended fixed commands and rejected shell access, general `systemctl`,
brightness default-setting and extra arguments.

The actual installed Firefox was exercised using a temporary profile and build-only Marionette flags:

- Every configured enterprise policy was accepted and active.
- Exactly one initial tab loaded `https://4thewords.com/`, with title “4thewords - Fight Monsters by Writing | Gamified Writing App”.
- A clicked test link to `https://example.com/4tw-link-test` reached Firefox's `blockedByPolicy` error, not the external page.
- Direct navigation to `https://example.org/4tw-direct-test` was likewise blocked.
- TLS bypass was not enabled (`acceptInsecureCerts=false`).
- The temporary profile/metadata and debugging flags were removed/excluded afterwards.

See `artifacts/browser-smoke.json` and `firefox-smoke.log`. Headless Firefox does not provide a meaningful physical fullscreen check; fullscreen was checked separately in the VM. WSL headless tests reported host user-namespace/framebuffer limitations; no sandbox-disable flags were added to the image.

## Isolated VM checks

### Final dual-mode IMG

The final dual-mode IMG booted twice using Ubuntu OVMF's Microsoft-key Secure
Boot template and disposable disk snapshots. Its serial console showed exactly
`4TW Online` and `Offline Typewriter`, with Online highlighted and a visible
countdown from five seconds. The untouched default reached the branded Sway
background and only the fixed Retry Wi-Fi / Offline Typewriter / Shut Down
prompt, as expected with no credentials and no emulated NIC
(`vm-dual-default-online-ready.png`).

On the second snapshot, Down/Enter selected the real Offline GRUB entry before
timeout. The guest reached the centred Plymouth logo, mounted WRITING, created
and opened `/writing/Drafts/Draft-2026-09-08-1327.txt`, then displayed
FocusWriter fullscreen (`vm-dual-offline-focuswriter.png`). Ctrl+Alt+B displayed
the expected no-battery/no-dGPU overlay above FocusWriter
(`vm-dual-offline-battery.png`). Alt+F4 left the fullscreen typewriter intact
and exposed no shell or desktop (`vm-dual-offline-after-alt-f4.png`).
Ctrl+Alt+Delete then shut the VM down and removed its QMP socket, confirming
complete power-off. Snapshot writes were discarded; the verified base IMG was
not altered.

The QEMU guest had no network or Acer battery/backlight hardware. The fixed
same-boot Wi-Fi-failure-to-Offline command path is statically verified, but its
button was not clicked in this VM run. Real Wi-Fi success and physical device
behavior remain Acer tests. These screenshots preceded the final targeted
`4tw-online` retry-monitor correction; the visible prompt and all boot/session
components are unchanged. The corrected helper was instead revalidated in the
configured rootfs, installed as the only file changed in the existing IMG, and
then confirmed by the complete real-image verifier. No second complete image
was built.

### Earlier single-mode regression evidence

QEMU 10.2.1 used Ubuntu OVMF's **Microsoft-key Secure Boot template**, SMM enabled, the removable USB boot path, and a disposable disk snapshot. No host/internal disk was exposed. No guest Wi-Fi adapter was emulated, so the booted Firefox correctly showed its connection-error page for **4thewords.com**, with no address bar, tabs, taskbar or desktop UI.

Observed on the actual image:

- Ubuntu EFI chain reached the correctly centred Plymouth logo and then fullscreen Firefox.
- Ctrl+Alt+B displayed “Battery information unavailable” above Firefox, appropriate for a VM without a battery; it then disappeared automatically.
- The enhanced notification also displayed `dGPU: unavailable`, appropriate for a VM without a PCI NVIDIA display device.
- Ctrl+Alt+Right displayed “Brightness control unavailable”, appropriate for a VM without a laptop backlight.
- Alt+F4 did not close Firefox or expose a shell/desktop.
- Ctrl+Alt+Delete powered the VM completely off.
- QEMU's emulated physical power-button event also powered the VM completely off.

Screenshots include `vm-first-boot.png`, `vm-kiosk.png`, `vm-battery-4s.png`, `vm-battery-7s.png`, `vm-brightness-4s.png` and `vm-after-alt-f4.png`. Under software CPU emulation the helpers needed several seconds to start; early screenshots preceded the notification. A separate headless Sway/Mako test confirmed that the notification list became populated and then empty after timeout (`test-notifications.log`). No notification-code change was needed.

The slow VM exposed an overly short 5-second CONFIG-device discovery deadline. This was corrected to **30 seconds in the existing IMG's fstab and future builder output**, without downloading packages, reassembling partitions, or creating a second complete IMG. The previous fstab is retained in `artifacts/fstab-before-timeout-fix.txt`; the final one is in `fstab-final.txt`. The correction concerns USB-device discovery, not Ethernet waiting. Image inspection and checksum generation are repeated after that targeted edit.

The power-optimised image passed read-only inspection, booted into fullscreen Firefox under Microsoft-key OVMF (`vm-power-battery-4s.png`), retained the kiosk after Alt+F4 (`vm-power-after-escape.png`), and powered off through Ctrl+Alt+Delete. Its Windows copy independently matched the final SHA-256 above. The VM had no network adapter; this does not verify real Wi-Fi association. BCLD remained unchanged in the final Git diff.

The UTC/timezone image also booted from the signed removable path under Microsoft-key OVMF with no emulated NIC. It reached the centred 4TW-OS logo and then the fullscreen Firefox 4thewords offline page; the absence of connectivity did not delay or prevent kiosk startup. Alt+F4 left the kiosk intact (`vm-timezone-after-escape-10s.png`), and Ctrl+Alt+Delete powered the VM off completely. The Windows IMG copy independently matched the final SHA-256 above. The no-network VM deliberately could not exercise a real public-IP timezone response.

## Exact dual-mode implementation in the final IMG

| Responsibility | Runtime file or setting |
| --- | --- |
| Pre-boot choice | `/boot/grub/grub.cfg`; two menu entries pass `4tw.mode=online` or `4tw.mode=offline` |
| Windows default override | `4TW-CONFIG/4tw-boot.cfg`, located by FAT label and read before the fixed five-second timeout |
| Mode validation/configuration | `/usr/local/lib/4tw/appliance.py` and `/usr/local/sbin/4tw-configure` |
| Shared appliance controls | `/etc/4tw/sway.conf` |
| Online session | `/etc/4tw/sway-online.conf` and `/usr/local/libexec/4tw-online` |
| Wi-Fi failure actions | `4tw-retry-wifi`, `4tw-switch-offline`, `4tw-enter-offline`, `4tw-poweroff`; exact sudo rules in `/etc/sudoers.d/4tw-kiosk` |
| Offline session | `/etc/4tw/sway-offline.conf` and `/usr/local/libexec/4tw-typewriter` |
| Offline network stop / WRITING mount | `enter_offline()` in `/usr/local/lib/4tw/appliance.py`; exact `/writing` UUID/options in `/etc/fstab` |
| Document selection/creation | `recent_writing_document()` and `ensure_writing_document()` in `/usr/local/lib/4tw/appliance.py` |
| FocusWriter defaults/recovery | runtime QSettings generated by `4tw-typewriter`; persistent `XDG_DATA_HOME=/home/kiosk/.local/share` for FocusWriter's application/recovery data |

## Exact timezone implementation in the final IMG

| Responsibility | Runtime file or setting |
| --- | --- |
| UTC hardware RTC | `/etc/adjtime`; initial `/etc/localtime` and `/etc/timezone` use `Etc/UTC` |
| NTP/RTC synchronization | enabled `chrony.service`; `rtcsync` in `/etc/chrony/chrony.conf` |
| Config validation and last-known logic | `/usr/local/lib/4tw/appliance.py` |
| Automatic service | `/etc/systemd/system/4tw-timezone-auto.service` |
| Connectivity trigger | `/etc/NetworkManager/dispatcher.d/50-4tw-timezone` |
| Provider isolation/mapping | `/etc/4tw/timezone-provider.json` and `/usr/local/lib/4tw/timezone_provider.py`; provider returns the IANA name directly, which is checked against installed `tzdata` |
| Last-known timezone | `/var/lib/4tw/timezone`, written only after a successful changed automatic result |
| Manual override | `timezone=` in the writable `4TW-CONFIG/4tw.cfg`; valid IANA values suppress all provider calls |

## Still requires the physical Acer

These are **not claimed as hardware-verified**:

- Firmware Secure Boot acceptance under the Acer's actual trusted/revoked-key state and F12 boot menu.
- Five-second physical boot-menu timing and changing the default through the
  flashed USB's `4TW-CONFIG/4tw-boot.cfg`.
- Configuration partition mounting and real Wi-Fi association, including that network's security mode and all three fixed failure-prompt buttons.
- Full 4thewords rendering, login, writing/save/sync, audio, and any supporting-domain requirements.
- Clicked external-link blocking in the actual logged-in workflow.
- Actual Wi-Fi/radio disablement in Offline mode; same-boot transition from a
  failed real Wi-Fi connection; return to enabled Wi-Fi on the next Online boot.
- FocusWriter typing, Ctrl+S/Save As/Open dialogs, recent Windows-created file
  selection, recovery after an unclean stop, clean FAT unmount, and Windows 11
  visibility/read/write of `4TW-WRITING` on the SanDisk.
- Real battery percentage/status/power/runtime values.
- Actual panel brightness, default 50%, 10–100% limits, both brightness directions.
- Physical keyboard shortcut operation, clean Ctrl+Alt+Delete shutdown and the laptop power button.
- Integrated/discrete GPU selection, runtime power state and battery life.
- Successful public-IP timezone detection on the Acer's real Wi-Fi; correct Darwin/Adelaide/other-state results; VPN/proxy behaviour; DST display; and Windows coexistence after manually setting `RealTimeIsUniversal=1`.

After flashing, fill in only the USB's `4tw.cfg`, boot with Secure Boot enabled, complete these checks plus the Darwin/manual/travel checklist in `TIMEZONE.md`, and always use clean shutdown before unplugging. The USB is unencrypted and must not be treated as protection against physical tampering.
