# 4TW-OS — Ubuntu/Sway Release

This is a separate implementation. The existing `../bcld/` prototype is unchanged.

Ubuntu 26.04 amd64 → Microsoft-signed Ubuntu shim → Canonical-signed GRUB and kernel → systemd → automatic kiosk login → Sway → one Firefox kiosk window at `https://4thewords.com/`.

Firefox uses Mozilla's official APT repository, not Snap or a third-party browser build. There is no desktop environment, bar, launcher, file manager, terminal shortcut, SSH server, or general passwordless sudo. Closing Firefox or Sway requests shutdown; it does not open a shell.

## Build from Windows 11

Use **PowerShell**. You do not need to open an Ubuntu desktop. These commands call the already installed `Ubuntu-26.04` WSL2 distribution directly.

```powershell
Set-Location -LiteralPath 'C:\Users\jonbe\Documents\AI projects\4TW-OS'
wsl.exe -l -v

wsl.exe -d Ubuntu-26.04 -u root --cd '/mnt/c/Users/jonbe/Documents/AI projects/4TW-OS' -- bash ubuntu-sway/build/run-wsl.sh packages
if ($LASTEXITCODE -ne 0) { throw 'Package preparation failed' }

wsl.exe -d Ubuntu-26.04 -u root --cd '/mnt/c/Users/jonbe/Documents/AI projects/4TW-OS' -- bash ubuntu-sway/build/run-wsl.sh configure
if ($LASTEXITCODE -ne 0) { throw 'Configuration/tests failed' }

wsl.exe -d Ubuntu-26.04 -u root --cd '/mnt/c/Users/jonbe/Documents/AI projects/4TW-OS' -- bash ubuntu-sway/build/run-wsl.sh image
if ($LASTEXITCODE -ne 0) { throw 'Image creation failed' }

# Make one normal Windows copy; sparse rsync transfers across WSL/NTFS are slow.
Copy-Item -LiteralPath '\\wsl.localhost\Ubuntu-26.04\home\jonbe\4tw-ubuntu-sway-build\artifacts\4TW-OS_RELEASE.img' -Destination '.\ubuntu-sway\artifacts\4TW-OS_RELEASE.img' -ErrorAction Stop

wsl.exe -d Ubuntu-26.04 -u root --cd '/mnt/c/Users/jonbe/Documents/AI projects/4TW-OS' -- bash ubuntu-sway/build/run-wsl.sh verify
if ($LASTEXITCODE -ne 0) { throw 'Image verification failed' }
```

Stop if any stage fails; do not continue to the next command. WSL's unrelated `Failed to translate D:\Program Files\ytdlp` PATH warning does not indicate a build failure.

The wrapper copies source and the existing `bcld/assets/4TW-OS.png` into the native Linux build directory:

```text
/home/jonbe/4tw-ubuntu-sway-build/
```

Builds run there, not on NTFS. The existing WSL tools are debootstrap, APT, Python 3, rsync, curl, GnuPG, GPT/loop/mount tools, FAT/ext4 tools and sbsigntool. No Docker, new Codex plugin, custom signing key, or Ubuntu GUI is needed. Internet access is needed for current signed indexes and packages missing from cache.

Successful stages copy logs/checksums back automatically; the explicit `Copy-Item` command exports the IMG to:

```text
C:\Users\jonbe\Documents\AI projects\4TW-OS\ubuntu-sway\artifacts\
    4TW-OS_RELEASE.img
    4TW-OS_RELEASE.img.sha256
    packages.tsv
    package-origins.txt
    *.log
```

The IMG builder deliberately refuses to overwrite an existing IMG. Before a later rebuild, move the existing native IMG and checksum to an explicitly named backup location. Keep any Windows copy you want to retain too. Do not delete the entire native build directory: it contains the reusable rootfs and cache.

The builder creates **one 12 GiB raw GPT disk image**, with a 256 MiB EFI partition, approximately 11.5 GiB ext4 system partition, and approximately 257 MiB FAT32 `4TW-CONFIG`. No ISO is needed. Several GiB remain available for the profile and future packages. It fits a nominal 32 GB USB.

Optional VM test tools were installed on the WSL host only. For another build host, `run-wsl.sh vm-tools` installs Ubuntu's QEMU/OVMF packages. They do not enter the USB image.

## Cache

The separate native cache is `.build-cache/apt/archives/`. Initial preparation copies compatible candidates from `/home/jonbe/bcld-4thewords-build/.build-cache/apt/archives/` without changing the old cache. APT/debootstrap still check signed Ubuntu/Mozilla indexes and package hashes; stale versions are not forced. The cache is bind-mounted only during package work, then unmounted and excluded from the image and Git.

## Flash and configure

1. Verify the Windows file hash:

   ```powershell
   Get-FileHash -Algorithm SHA256 -LiteralPath '.\ubuntu-sway\artifacts\4TW-OS_RELEASE.img'
   Get-Content -LiteralPath '.\ubuntu-sway\artifacts\4TW-OS_RELEASE.img.sha256'
   ```

2. Use Rufus or another raw-disk-image writer. Select **only the intended 32 GB SanDisk**, select this `.img`, and use raw/DD writing if asked. Flashing erases that USB. Do not select the internal SSD.
3. Reinsert the USB into Windows. Open the `4TW-CONFIG` volume and edit `4tw.cfg` in Notepad. If Windows offers to format a Linux partition, **cancel**.
4. Supply the Base64 SSID/password on the USB only. Leave `start_url=https://4thewords.com/` unchanged unless another approved path is required. Keep `timezone=auto`, or enter a valid IANA name such as `timezone=Australia/Darwin` for a manual override. Do not add quotation marks around values.
5. Safely eject, then use the Acer's F12 menu to boot the USB with Secure Boot still enabled.

Generate Base64 without embedding the password in PowerShell history:

```powershell
$wifiName = Read-Host 'Wi-Fi network name'
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wifiName))

$wifiSecret = Read-Host 'Wi-Fi password' -AsSecureString
$wifiPlain = [Net.NetworkCredential]::new('', $wifiSecret).Password
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wifiPlain))
Remove-Variable wifiPlain, wifiSecret, wifiName
```

Copy each result into the corresponding `wifi_ssid_b64=` or `wifi_psk_b64=` line. **Base64 is not encryption:** the displayed text and USB file reveal the credentials to anyone who decodes them. Close that PowerShell window afterwards. The parser accepts only the four documented keys, never evaluates shell text, and rejects invalid/duplicate keys. Both credentials must be filled or both empty; this version supports personal WPA/WPA2/WPA3-transition PSK networks, not enterprise EAP or captive portals. Runtime NetworkManager credentials are written under `/run`, not persisted to the OS filesystem.

Wi-Fi is attempted directly, with a bounded startup timeout. Ethernet is unmanaged and wait-online services are disabled. Without Wi-Fi, Firefox still opens and may show a connection error; retry the page after connectivity returns.

## Clock and travel

The laptop hardware clock is always treated as UTC. Chrony keeps network time enabled and uses normal `rtcsync`; the displayed timezone is separate. In `timezone=auto`, 4TW-OS immediately applies the last successful IANA timezone (or `Etc/UTC` on a fresh image), starts the kiosk normally, and makes at most one four-second request per boot to `https://ipapi.co/timezone/` after connectivity exists. Only the returned timezone name is used and persisted. A valid manual `timezone=` value suppresses that online request entirely. VPNs and proxies can make public-IP location inaccurate. See `docs/TIMEZONE.md` for privacy, failure behaviour, Windows coexistence and the physical test checklist.

Windows must separately be configured once to interpret the RTC as UTC using the `RealTimeIsUniversal` DWORD described in that document. 4TW-OS does not mount or alter Windows, its registry, EFI partition, BitLocker, TPM, Secure Boot settings or the internal SSD.

## Controls

| Shortcut | Action |
| --- | --- |
| Ctrl+Alt+B | Battery notification, automatically disappears after 5 seconds |
| Ctrl+Alt+Left | Brightness down approximately 10 percentage points |
| Ctrl+Alt+Right | Brightness up approximately 10 percentage points |
| Ctrl+Alt+Delete | Sync and clean system power-off |

Brightness defaults to approximately 50%, with a 10–100% range. Missing battery/rate/backlight data produces an unavailable message or omitted field, not fabricated values. Runtime estimates are approximate and shown only while discharging with usable measurements. The battery overlay also reports the NVIDIA display device as `suspended`, `active` or `unavailable` when that state can be determined reliably. The normal physical power button requests clean power-off. Lid closing is configured to do nothing; use shutdown before packing the laptop away.

Editing shortcuts such as copy/paste, undo, select-all and bold remain available. Browser-management shortcuts are intercepted globally. No terminal appears. PipeWire/WirePlumber supplies normal browser audio without a mixer application.

## Website policy and security

`config/allowed-sites.json` is the single supporting-domain allowlist. Initially only HTTPS on `4thewords.com` and its subdomains is allowed. `policies/policies.json` supplies native Firefox restrictions; the builder inserts the allowlist. Extend that JSON and rebuild if physical testing identifies a necessary supporting domain. An added domain also permits ordinary navigation there; add only trusted, necessary domains. There is no IP-based website firewall and no TLS certificate bypass.

Firefox's native WebsiteFilter governs website navigation; this is not a promise that every background browser/network request is restricted to those hosts. Kiosk mode and Sway prevent ordinary browser management. This is a personal appliance, not protection against someone physically rewriting its unencrypted USB partitions.

The signed EFI/kernel binaries are copied unmodified from authenticated Ubuntu packages. Booting uses the removable `EFI/BOOT/BOOTX64.EFI` path; the build never runs `grub-install` or `efibootmgr`, and never modifies Windows EFI, the internal SSD, BitLocker or host NVRAM. The Acer firmware must trust the standard Microsoft third-party UEFI CA used by Ubuntu and accept the installed shim/GRUB versions under its revocation policy. No custom MOK is required. Acer acceptance must still be tested physically.

The integrated GPU is preferred when Linux reports it driving the internal panel. A sole GPU remains usable, and ambiguous multi-GPU layouts fall back to Sway/wlroots detection rather than a guessed PCI address. NVIDIA PCI functions use normal kernel runtime autosuspend where supported; no proprietary NVIDIA driver, forced device removal or discrete-GPU rendering configuration is installed. Hardware power states still need measurement on the Acer.

## Persistence and updates

The normal ext4 system and Firefox profile persist, including cookies and website storage needed for login. Startup tabs are not restored; each boot opens only the configured URL. `/tmp`, `/var/tmp`, logs and browser cache use RAM; root uses `noatime`, and Firefox recovery-state writes are limited to five-minute intervals. There is no USB swap. Always shut down cleanly before removing power or the USB.

For Ubuntu/Firefox updates, back up anything important and rebuild using the same four stages above. The packages stage refreshes signed indexes and installs current packages; configure regenerates initramfs and validates the kiosk; image copies the current signed boot chain. Reflash the new image, restore `4tw.cfg`, and log in again. Reflashing resets the old profile, so ensure writing has synced to 4thewords first. Automatic APT timers are intentionally disabled to avoid unattended writes during a writing session. There is no kiosk-admin shell or SSH path.

`/usr/local/sbin/4tw-refresh-boot` exists for a future administrator doing offline maintenance of a mounted installation. It is not available through kiosk sudo and never changes NVRAM. Rebuilding is the documented update route.

## Verification

See `docs/BUILD-NOTES.md`, `docs/VERIFICATION.md`, `docs/POWER-OPTIMISATION.md`, `docs/TIMEZONE.md`, and the actual artifact logs. Static verification mounts the final IMG read-only, checks its partitions/files/signatures/configuration, tests a copy of the FAT configuration partition for writes, and rechecks SHA-256 afterwards. The build-only Firefox test uses a temporary profile and temporary automation flags; neither is shipped. Physical Acer checks are explicitly separate.

Implementation references: [Ubuntu Secure Boot](https://documentation.ubuntu.com/security/docs/security-features/platform-protections/secure-boot/), [Mozilla official Linux packages](https://support.mozilla.org/en-US/kb/install-firefox-linux), [Firefox kiosk mode](https://support.mozilla.org/en-US/kb/firefox-enterprise-kiosk-mode), [WebsiteFilter](https://firefox-admin-docs.mozilla.org/reference/policies/websitefilter/), [Firefox policies](https://mozilla.github.io/policy-templates/), [Sway configuration](https://manpages.ubuntu.com/manpages/resolute/man5/sway.5.html), [Mako overlay configuration](https://manpages.ubuntu.com/manpages/resolute/man5/mako.5.html).
