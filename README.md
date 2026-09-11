# 4TW-OS — Ubuntu/Sway Release

This Ubuntu/Sway implementation is self-contained.

Ubuntu 26.04 amd64 → Microsoft-signed Ubuntu shim → Canonical-signed GRUB and kernel → a two-choice appliance menu → systemd → automatic kiosk login → Sway → either one Firefox kiosk at `https://4thewords.com/` or one fullscreen Offline Typewriter.

Firefox uses Mozilla's official APT repository, not Snap or a third-party browser build. There is no desktop environment, bar, launcher, file manager, terminal shortcut, SSH server, or general passwordless sudo. Closing Firefox or Sway requests shutdown; it does not open a shell.

## Install the latest release

1. Download `4TW-OS_RELEASE.img.zst` and
   `4TW-OS_RELEASE.img.zst.sha256` from the latest GitHub Release.
2. Download or open Rufus 4.7 or newer.
3. Select the intended USB drive and select `4TW-OS_RELEASE.img.zst` directly.
4. Click Start and wait for Rufus to decompress and write the image.

**Do not extract the `.img.zst` first.** Rufus supports Zstandard-compressed
disk images directly and decompresses the raw IMG while flashing. Confirm the
selected USB carefully: it will be erased. The internal SSD must not be
selected.

## Release files versus repository files

The Git repository contains source code, scripts, documentation and assets. It
does not contain the generated release binary. GitHub Releases contain the
public `4TW-OS_RELEASE.img.zst` and its `.sha256` file; maintainers must upload
those as Release assets rather than commit them to ordinary Git history.

## Building 4TW-OS from source

Developers, contributors and people creating a custom build can download and
extract this repository, then double-click **`BUILD-4TW-OS.cmd`**. Follow any
one-time WSL or Ubuntu account-setup instructions and rerun the same CMD after
a requested restart or setup pause. The launcher finishes all build,
verification, compression and Windows-export stages without opening Ubuntu or
running a separate command.

The compressed release, checksum and concise report are placed in
`Downloads\4TW-OS\`. The verified 16 GiB raw IMG remains an internal artifact
in native WSL storage and is not copied to Windows. The launcher never selects,
erases or writes a USB. See `docs/WINDOWS-BUILDER.md` for details.

### Manual developer build from Windows 11

Developers may run the tested stages individually. Open PowerShell in this repository's root
(the directory containing this README, `build/` and `assets/`). You do not need
an Ubuntu desktop. These commands call `Ubuntu-26.04` WSL2 directly and support
repository paths containing spaces.

```powershell
wsl.exe -l -v
$repoWindows = (Get-Location).Path
$repoWsl = (wsl.exe -d Ubuntu-26.04 -- wslpath -a -u $repoWindows).Trim()
if ($LASTEXITCODE -ne 0 -or -not $repoWsl) { throw 'Could not resolve the repository path in WSL' }

wsl.exe -d Ubuntu-26.04 -u root --cd $repoWsl -- bash build/run-wsl.sh host-deps
if ($LASTEXITCODE -ne 0) { throw 'Build-host dependency setup failed' }

wsl.exe -d Ubuntu-26.04 -u root --cd $repoWsl -- bash build/run-wsl.sh all
if ($LASTEXITCODE -ne 0) { throw 'Release build or verification failed' }
```

`all` executes package preparation, configuration, IMG construction, exact IMG
verification, and Zstandard release compression in order. It stops on the
first failure. The `packages`, `configure`, `image`, `verify` and `release`
dispatches remain available for diagnostics and safe resume. Do not continue
manually after a failed stage.

All build stages require WSL root because they create device nodes, chroot
mounts, filesystems and loop devices. `run-wsl.sh` determines the non-root WSL
account from `FOURTW_WSL_USER`, `SUDO_USER`, `/etc/wsl.conf`, or one unambiguous
normal login account, in that order. It rejects root, missing homes and homes on
`/mnt`. If the host has several eligible WSL users and no default, explicitly
pass `FOURTW_WSL_USER` through `env` rather than editing source.

The wrapper copies source, including the required project-local
`assets/4TW-OS.png`, into:

```text
<selected WSL user's home>/4tw-ubuntu-sway-build/
```

Builds run there, not on NTFS. A missing or externally linked logo fails before
source synchronization. `host-deps` idempotently installs only the normal IMG
builder's required Ubuntu tools; QEMU remains optional. No Docker, Codex plugin,
custom signing key or Ubuntu GUI is needed. Internet access is required when
the authenticated package workflow needs current indexes or packages.

Successful stages copy small logs and checksums back to `artifacts\`; they do
not repeatedly copy the large sparse IMG or compressed `.img.zst`. The public
launcher exports the compressed release once, and only after raw and compressed
verification, to `Downloads\4TW-OS\` and hashes that Windows copy again. If runtime source changed, `all` safely archives the last
verified native output under `artifacts/previous/` before constructing its
replacement. It retains at most one previous image. An unverified existing IMG
is never overwritten or presented as ready.

The builder creates **one 16 GiB raw GPT disk image**, with a 256 MiB EFI partition, approximately 11.5 GiB ext4 system partition, 256 MiB FAT32 `4TW-CONFIG`, and approximately 4 GiB FAT32 `4TW-WRITING`. It is still one Ubuntu root filesystem, not two operating systems. No ISO is needed, and the image fits a nominal 32 GB USB. The verified raw IMG is preserved in native WSL for development; `zstd -T0 -10` creates the smaller public `.img.zst` without changing it.

Optional VM test tools were installed on the WSL host only. For another build host, `run-wsl.sh vm-tools` installs Ubuntu's QEMU/OVMF packages. They do not enter the USB image.

## Cache

The primary cache is
`<native build directory>/.build-cache/apt/archives/`. It is build-time only,
ignored by Git, excluded from the IMG, automatically recreated and safe to
delete when a clean download is desired. APT/debootstrap still check signed
Ubuntu/Mozilla indexes and package hashes; stale versions are not forced. The
cache is bind-mounted only during package work, then unmounted.

A previous cache is optional. To seed from one, set `FOURTW_OLD_APT_CACHE` to
its absolute native-Linux `apt/archives` directory for the `packages` command.
Only missing `.deb` files are copied; the source cache is never changed. An
unset or missing optional cache is the normal fresh-clone case and is silent.

## Configure a flashed USB

1. Verify the Windows file hash:

   ```powershell
   Get-FileHash -Algorithm SHA256 -LiteralPath '.\4TW-OS_RELEASE.img.zst'
   Get-Content -LiteralPath '.\4TW-OS_RELEASE.img.zst.sha256'
   ```

2. With Rufus 4.7 or newer, select **only the intended 32 GB SanDisk** and select the `.img.zst` directly. Do not extract it first. Flashing erases that USB. Do not select the internal SSD.
3. Reinsert the USB into Windows. Open `4TW-CONFIG` and edit `4tw.cfg` in Notepad. If Windows offers to format an unfamiliar Linux or EFI partition, **cancel**. `4TW-WRITING` is the normal Windows-readable document volume.
4. Supply the Base64 SSID/password on the USB only. Leave `start_url=https://4thewords.com/` unchanged unless another approved path is required. Keep `timezone=auto`, or enter a valid IANA name such as `timezone=Australia/Darwin` for a manual override. `keyboard_backlight=off` requests an initial off state when Linux exposes a standard keyboard LED; use `keep` to retain the firmware state. Do not add quotation marks around these values.
5. Optionally edit `4tw-boot.cfg`: use `set default_mode="online"` or `set default_mode="offline"`. The five-second menu always keeps both choices; invalid/missing settings default Online. This change never requires a rebuild or reflash.
6. Safely eject, then use the Acer's F12 menu to boot the USB with Secure Boot still enabled.

Generate Base64 without embedding the password in PowerShell history:

```powershell
$wifiName = Read-Host 'Wi-Fi network name'
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wifiName))

$wifiSecret = Read-Host 'Wi-Fi password' -AsSecureString
$wifiPlain = [Net.NetworkCredential]::new('', $wifiSecret).Password
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wifiPlain))
Remove-Variable wifiPlain, wifiSecret, wifiName
```

Copy each result into the corresponding `wifi_ssid_b64=` or `wifi_psk_b64=` line. **Base64 is not encryption:** the displayed text and USB file reveal the credentials to anyone who decodes them. Close that PowerShell window afterwards. The parser accepts only the five documented keys, never evaluates shell text, and rejects invalid/duplicate keys. Both credentials must be filled or both empty; this version supports personal WPA/WPA2/WPA3-transition PSK networks, not enterprise EAP or captive portals. Runtime NetworkManager credentials are written under `/run`, not persisted to the OS filesystem.

Wi-Fi is attempted directly, with a bounded startup timeout. Ethernet is unmanaged and wait-online services are disabled. On failure, a fixed overlay offers Retry Wi-Fi, Offline Typewriter, or Shut Down. It never switches modes without the user's choice.

## Two appliance modes

The GRUB menu passes exactly one `4tw.mode=online` or `4tw.mode=offline` parameter into the shared Ubuntu installation. Online preserves the existing Wi-Fi/Firefox/4thewords kiosk. Offline does not launch Firefox or automatic timezone lookup; it stops NetworkManager and chrony for that boot, mounts only `4TW-WRITING` at `/writing` with `noexec,nodev,nosuid`, and launches Ubuntu's packaged FocusWriter fullscreen.

FocusWriter defaults to UTF-8 `.txt` files and `/writing/Drafts`. The most recently modified eligible `.txt` opens, or a persistent timestamped Draft is created. FocusWriter 1.9.0 has a persistent five-minute emergency recovery cache but no ordinary timed file autosave, so **Ctrl+S remains necessary**. Its own New/Open/Save/Save As dialogs stay usable. See `docs/DUAL-MODE.md` for Windows access and the Acer test checklist.

## Clock and travel

Windows owns the laptop RTC and keeps normal Windows local wall-clock semantics. 4TW-OS reads its date/time fields once at boot, after selecting the manual or last-known IANA timezone, and uses them only to initialise the Linux system clock. Chrony then corrects the Online Linux system clock from network time. RTC synchronisation directives, Chrony's RTC device access and hardware-clock save units are disabled; `/etc/adjtime` is deliberately absent. 4TW-OS never writes the physical RTC.

In `timezone=auto`, 4TW-OS uses the last successful IANA timezone (or `Etc/UTC` on a fresh image) immediately and makes at most one four-second request per boot to `https://ipapi.co/timezone/` after connectivity exists. A validated manual `timezone=` value suppresses that request. VPNs and proxies can make public-IP location inaccurate. Windows must **not** retain the previously suggested `RealTimeIsUniversal=1`; remove that value manually and leave Windows automatic time enabled. See `docs/TIMEZONE.md` for the implementation, Offline/travel edge cases and deferred physical checklist. 4TW-OS does not mount or alter Windows, its registry, EFI partition, BitLocker, TPM, Secure Boot settings or internal SSD.

## Controls

| Shortcut | Action |
| --- | --- |
| Ctrl+Alt+B | Battery notification, automatically disappears after 5 seconds |
| Ctrl+Alt+Left | Brightness down approximately 10 percentage points |
| Ctrl+Alt+Right | Brightness up approximately 10 percentage points |
| Fn+F11 / keyboard illumination down | Keyboard illumination down to Off when exposed as `XF86KbdBrightnessDown` |
| Fn+F12 / keyboard illumination up | Keyboard illumination up when exposed as `XF86KbdBrightnessUp` |
| Ctrl+Alt+Delete | Sync and clean system power-off |

LCD brightness defaults to approximately 50%, with a 10–100% range. Keyboard illumination uses the LED device's native levels when the kernel exposes one and defaults to Off; `keyboard_backlight=keep` on `4TW-CONFIG` leaves its firmware state alone. Changes show a temporary Mako notification. Missing battery/rate/backlight data produces an unavailable message or omitted field, not fabricated values. Runtime estimates are approximate and shown only while discharging with usable measurements. The battery overlay also reports the NVIDIA display device as `suspended`, `active` or `unavailable` when that state can be determined reliably. The normal physical power button requests clean power-off. Lid closing is configured to do nothing; use shutdown before packing the laptop away. See `docs/KEYBOARD-BACKLIGHT.md` for the conditional hardware support and test procedure.

Editing shortcuts such as copy/paste, undo, select-all and bold remain available. Browser-management shortcuts are intercepted in Online mode; FocusWriter's writing commands remain available Offline. No terminal appears. PipeWire/WirePlumber supplies normal browser audio without a mixer application.

## Website policy and security

`config/allowed-sites.json` is the single supporting-domain allowlist. Initially only HTTPS on `4thewords.com` and its subdomains is allowed. `policies/policies.json` supplies native Firefox restrictions; the builder inserts the allowlist. Extend that JSON and rebuild if physical testing identifies a necessary supporting domain. An added domain also permits ordinary navigation there; add only trusted, necessary domains. There is no IP-based website firewall and no TLS certificate bypass.

Firefox's native WebsiteFilter governs website navigation; this is not a promise that every background browser/network request is restricted to those hosts. Kiosk mode and Sway prevent ordinary browser management. This is a personal appliance, not protection against someone physically rewriting its unencrypted USB partitions.

The signed EFI/kernel binaries are copied unmodified from authenticated Ubuntu packages. Booting uses the removable `EFI/BOOT/BOOTX64.EFI` path; the build never runs `grub-install` or `efibootmgr`, and never modifies Windows EFI, the internal SSD, BitLocker or host NVRAM. The Acer firmware must trust the standard Microsoft third-party UEFI CA used by Ubuntu and accept the installed shim/GRUB versions under its revocation policy. No custom MOK is required. Acer acceptance must still be tested physically.

The integrated GPU is preferred when Linux reports it driving the internal panel. A sole GPU remains usable, and ambiguous multi-GPU layouts fall back to Sway/wlroots detection rather than a guessed PCI address. NVIDIA PCI functions use normal kernel runtime autosuspend where supported; no proprietary NVIDIA driver, forced device removal or discrete-GPU rendering configuration is installed. Hardware power states still need measurement on the Acer.

## Persistence and updates

The normal ext4 system, Firefox profile and FocusWriter emergency recovery state persist. Offline documents persist separately on `4TW-WRITING`. Startup tabs are not restored; Online opens only the configured URL. `/tmp`, `/var/tmp`, logs and browser cache use RAM; root uses `noatime`, and Firefox recovery-state writes are limited to five-minute intervals. There is no USB swap. Always shut down cleanly before removing power or the USB so the writable FAT32 filesystem is unmounted safely.

For Ubuntu/Firefox updates, back up anything important and rebuild using the same five native stages above. The packages stage refreshes signed indexes and installs current packages; configure regenerates initramfs and validates the kiosk; image copies the current signed boot chain; verification gates Zstandard compression and Windows export. Reflash the new release, restore `4tw.cfg`, and log in again. Reflashing resets the old profile, so ensure writing has synced to 4thewords first. Automatic APT timers are intentionally disabled to avoid unattended writes during a writing session. There is no kiosk-admin shell or SSH path.

`/usr/local/sbin/4tw-refresh-boot` exists for a future administrator doing offline maintenance of a mounted installation. It is not available through kiosk sudo and never changes NVRAM. Rebuilding is the documented update route.

## Verification

See `docs/BUILD-NOTES.md`, `docs/VERIFICATION.md`, `docs/DUAL-MODE.md`,
`docs/POWER-OPTIMISATION.md`, `docs/TIMEZONE.md`, `docs/PORTABILITY.md`, and
the actual artifact logs. Static verification mounts the final IMG read-only,
checks all partitions/files/signatures/configuration, write-tests copies of
both FAT data partitions, and rechecks SHA-256 afterwards. Build-only Firefox
and FocusWriter tests use temporary state that is not shipped. Physical Acer
checks are explicitly separate.

Implementation references: [Ubuntu Secure Boot](https://documentation.ubuntu.com/security/docs/security-features/platform-protections/secure-boot/), [Mozilla official Linux packages](https://support.mozilla.org/en-US/kb/install-firefox-linux), [Firefox kiosk mode](https://support.mozilla.org/en-US/kb/firefox-enterprise-kiosk-mode), [WebsiteFilter](https://firefox-admin-docs.mozilla.org/reference/policies/websitefilter/), [Firefox policies](https://mozilla.github.io/policy-templates/), [Sway configuration](https://manpages.ubuntu.com/manpages/resolute/man5/sway.5.html), [Mako overlay configuration](https://manpages.ubuntu.com/manpages/resolute/man5/mako.5.html).
