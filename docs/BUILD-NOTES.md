# Build notes - 11 September 2026

## Keyboard-backlight source change (no IMG build)

The shared Sway appliance layer now handles only the dedicated
`XF86KbdBrightnessDown` and `XF86KbdBrightnessUp` keysyms through a bounded,
root-owned standard-LED helper. The helper dynamically detects
`/sys/class/leds/*:kbd_backlight`, supports native discrete levels including
zero, and reuses the existing five-second Mako notification. The strict CONFIG
parser accepts `keyboard_backlight=off|keep`; `off` is the credential-free
default and is a no-op when no recognised LED exists.

The Ubuntu rootfs already contains the in-tree, signed `acer_wmi` from
`linux-image-generic`; no package was added and `brightnessctl` is not needed.
No third-party Acer/Nitro module, broad sysfs permission, general sudo command,
terminal, panel or tray was added. The exact sudo additions are only the fixed
helper's `up` and `down` operations. Plain F11/F12 and the existing LCD
brightness bindings were not changed.

Static tests and configured-rootfs validation for this source-only change are
recorded in `docs/KEYBOARD-BACKLIGHT.md` and `docs/VERIFICATION.md`. Per the
task constraint, `build-img.sh` was not run and the previously verified IMG
was not modified. Physical Nitro V16S AI LED/event support remains deferred to
the next combined build.

The implementation is self-contained in this repository. No BCLD source, previous BCLD artifact, internal disk, Windows EFI partition, BitLocker setting, or host firmware boot entry was changed.

## Zstandard public release stage (no IMG rebuild)

The low-click Windows builder now treats the raw IMG as an internal native-WSL
artifact and adds two final release stages after exact IMG verification. The
dedicated `build/compress-release.sh` stage rechecks the IMG against
`verify-img`'s recorded hash, binds its output to that raw hash, runs
`zstd -T0 -10`, tests the resulting stream, hashes it, and applies the strict
GitHub Release check of less than 2,147,483,648 bytes. Windows then copies only
the compressed release through a `.partial` filename and independently hashes
that copy before publishing its final name.

The existing verified 9 September raw IMG was used to exercise this stage; it
was not rebuilt or modified. The result was 1,457,909,845 bytes (1.36 GiB),
leaving about 658 MiB of headroom. `zstd --test` passed and both native WSL and
Windows produced this compressed-file SHA-256:

```text
c7e94459d727650406dc39750960e37f5b32ab76d93dcd511bc13e8b42abe89f
```

The Windows public artifacts are in
`%USERPROFILE%\Downloads\4TW-OS\`. This packaging test does not incorporate the
pending keyboard-backlight source change into the 9 September IMG; the next
normal launcher build will rebuild the source-changed raw IMG once, then run
the new compression and export stages. No package stage, package download,
rootfs configuration, IMG assembly, image edit or USB write was performed for
this compression test.

## Public-launcher Release build

The new `BUILD-4TW-OS.cmd` / `BUILD-4TW-OS.ps1` path completed one full Release
build on 9 September 2026. It detected the existing `Ubuntu-26.04` WSL2
distribution, dynamically resolved `/home/<build-user>/4tw-ubuntu-sway-build`,
passed both 18-GiB free-space checks, and invoked `build/run-wsl.sh all`.

Package preparation retained and reused all 1,062 native cached archives. The
signed index refresh found 14 current Ubuntu updates and downloaded only their
19.5 MB delta; the normal configured package set otherwise required no new
archives. Configuration then passed the helper, dual-mode, RTC, timezone,
rootfs, Sway, sudo, FocusWriter, and real-Firefox policy/navigation tests.

The orchestrator checksum-validated and preserved the preceding verified image
as `artifacts/previous/4TW-OS_RELEASE-2026-09-09-013620.img`, then invoked the
IMG builder exactly once. Final read-only verification passed all GPT,
filesystem, Release/kiosk, website-policy, credential-cleanliness, copied-FAT
write, RTC-policy, and Microsoft/Canonical Secure Boot signature checks. No
second IMG build was performed: after a Windows-export performance correction,
the launcher recognized and reused the already verified current image.

The launcher rechecked SHA-256 using native WSL I/O, copied the image once to a
temporary Windows `.partial` path, hashed all copied bytes, and published the
Rufus-ready name only after it matched. The public output is:

```text
%USERPROFILE%\Downloads\4TW-OS\4TW-OS_RELEASE.img
17,179,869,184 bytes
SHA-256: b8b1a10766bc71166f9299f68680c08e980d8ba302ce8390518d3f4e19db9a53
```

Windows PowerShell 5.1 parsed all launcher/module/test files. The mockable
launcher suite passed 23 checks covering spaces, ZIP use without Git, WSL and
Ubuntu states (including localized status text), restart/resume, first-run
setup, unrelated WSL diagnostic isolation, ambiguous-path rejection, stage
failure, disk space, Downloads resolution, source/copy checksums, bounded
prior-output retention, `.partial` failure safety, and path-identity regression.
The existing 14-test portability suite passed. All modified shell scripts passed
`bash -n` and warning-level Shellcheck. PSScriptAnalyzer was not installed and
was not added solely for this task.

## Environment and stages

Windows 11 PowerShell invoked the existing `Ubuntu-26.04` WSL2 distribution as root. Source was copied under the dynamically resolved non-root WSL home, in `4tw-ubuntu-sway-build/`, for native Linux ownership, filesystems and loop mounts. Exact Windows commands are in `README.md`.

1. `packages`: debootstrap Ubuntu Resolute amd64, authenticated Ubuntu APT repositories, Mozilla's official repository with its published signing-key fingerprint verified. Service startup was suppressed inside the build chroot. Its temporary `/dev` contained only basic character devices, not host disk devices.
2. `configure`: installed the root-owned overlay, native Firefox policies and original logo; created the kiosk account and persistent Firefox/FocusWriter state directories; generated initramfs; validated helpers, all three Sway configurations and sudo; exercised the actual Firefox and FocusWriter packages with temporary build-only state.
3. `image`: one complete 16 GiB raw GPT image assembled from the validated rootfs, using only loop-backed partitions in that new file. It contains one shared root filesystem plus EFI, CONFIG and WRITING partitions. Ubuntu's signed shim, GRUB, MokManager and kernel were retained byte-for-byte. No `grub-install` or `efibootmgr` was run.
4. `verify`: inspected the final IMG read-only and tested writes on separate copies of both FAT data partitions. VM testing used disposable QEMU disk snapshots and a copied OVMF variable store, not another complete image build.

Early validation caught two preparation issues before image assembly: a minimal `--no-install-recommends` installation required explicit initramfs/compression packages, and Firefox required a writable `.mozilla/firefox` metadata directory in addition to its explicit profile. Browser media codec libraries were also added after the initial headless test reported decoder errors. These were rootfs-stage corrections; no complete IMG was rebuilt to test them.

## Package versions

| Component | Installed version |
| --- | --- |
| Ubuntu | 26.04 LTS, amd64 |
| Firefox, Mozilla official APT | 155.0.1~build1 |
| Ubuntu generic kernel | 7.0.0-31.31 |
| shim-signed | 1.59+15.8-0ubuntu2 |
| grub-efi-amd64-signed | 1.215+2.14-2ubuntu1 |
| Sway | 1.11-3 |
| Mako | 1.10.0-1build1 |
| NetworkManager | 1.54.3-2ubuntu3 |
| PipeWire | 1.6.2-1ubuntu1.1 |
| FocusWriter | 1.9.0-1, Ubuntu resolute/universe |
| Qt Wayland support | qt6-wayland 6.10.2-4 |

Full inventory and repository candidates are recorded in `artifacts/packages.tsv` and `artifacts/package-origins.txt`.

## Cache use

The initial seed contained 939 existing BCLD download-cache packages. The first main package install needed **310 MB of downloads out of 1,143 MB of package archives**, reusing approximately 833 MB. The base upgrade downloaded 549 kB out of 19.4 MB. Initramfs tools and zstd were then installed entirely from cache; the media-codec addition downloaded about 10 MB out of 28.9 MB. Index refreshes and genuinely new versions were downloaded normally. Logs retain the APT `Need to get` evidence, including `artifacts/prepare-packages-initial.log` on Windows.

QEMU/OVMF required approximately 24 MB of additional build-host-only downloads for the optional boot test. These packages and all package-download caches are excluded from the USB image. No additional Codex plugins were used.

For the 7 September power-optimisation pass, the already prepared Ubuntu 26.04 rootfs and its external APT archive cache were reused. No package was added or changed, the `packages` stage was intentionally not rerun, and no package download occurred. Source/helper/browser validation completed before image assembly.

The 8 September UTC/timezone pass reused that same rootfs and cache. The `packages` stage was again intentionally not run: Python 3, NetworkManager, chrony and `tzdata` were already present, and no package was added, updated or downloaded. GeoClue and `libtimezonemap` were not installed. Static configuration, provider-failure, one-request, manual-override, kiosk and live-Firefox policy tests all passed before the existing IMG builder was invoked exactly once.

The dual-mode pass reused the same prepared rootfs and persistent APT cache,
which contained 1,034 archives. Adding Ubuntu's FocusWriter and native Qt
Wayland support installed 64 new packages (125 MB installed): APT reused 27.6
MB of the 41.1 MB package archive set and downloaded only the missing 13.5 MB.
No installed package was upgraded. Two initial APT index attempts safely stopped
while Mozilla's mirror was synchronizing; the unchanged authenticated workflow
succeeded once its signed indexes became consistent.

The 9 September portability pass changed build-host path discovery,
source-copy/cache-seed helpers, marker invalidation, Windows-facing commands,
line-ending/ignore rules and build-host tests only. The dynamic resolver chose
the same existing native directory, where 1,062 cached `.deb` files (1.9 GiB)
were already available, so no cache copy or package download was needed. All
build shell scripts passed `bash -n`; 13 isolated portability tests passed,
including non-root account selection, ambiguous-user failure, paths containing
spaces, project-local logo copying, missing-logo failure, and absent/present
optional-cache behavior. No package stage, rootfs configuration, image build,
image edit or VM run was performed, and the existing Release IMG was left
unchanged. See `docs/PORTABILITY.md`.

The 9 September RTC-ownership pass added no package and did not run the package
stage. It removed Ubuntu Chrony's active RTC synchronization directive while
retaining its network sources and `makestep`, denied chronyd access to physical
RTC devices, explicitly masked hardware-clock save units, and removed
`/etc/adjtime`. A fixed Python module now reads only the RTC's sysfs date/time
fields after the manual/last-known/UTC timezone is selected and sets only Linux
`CLOCK_REALTIME`. Timezone changes now update validated zoneinfo presentation
files directly rather than invoking a clock-management command. Focused unit
tests, the new active-runtime RTC audit, all existing helper tests, and the
complete `configure` stage were run without invoking the IMG builder or touching
the WSL/Windows host clock.

## Output and persistence

The current native deliverable is `artifacts/4TW-OS_RELEASE.img`,
17,179,869,184 bytes, with `4TW-OS_RELEASE.img.sha256`. Its SHA-256 is
`b8b1a10766bc71166f9299f68680c08e980d8ba302ce8390518d3f4e19db9a53`.
It contains the Windows-owned/no-write RTC policy, automatic/manual timezone
model, Online/Offline modes, power changes, and current launcher-built rootfs.
The root filesystem has about 8.5 GiB free and `4TW-WRITING` about 4.0 GiB free.

The earlier working image and checksum were preserved under `artifacts/pre-power-optimisation-2026-09-05/`. After all source/rootfs checks passed, exactly one new complete IMG was assembled for this optimisation pass. No post-build edit was needed. The CONFIG-device deadline remains 30 seconds from the earlier correction.

The immediately preceding power-optimised image and checksum were additionally preserved under `artifacts/pre-utc-timezone-2026-09-08/` before the timezone build. Exactly one new complete IMG was assembled after all timezone checks passed. The final image was then inspected read-only, and a copy of its CONFIG partition was write-tested without modifying the IMG.

Before the dual-mode build, the immediately preceding image and checksum were
preserved in both Windows and native WSL under
`artifacts/pre-dual-mode-2026-09-08/`. All helper, Sway, sudo, FocusWriter and
Firefox tests passed first. Exactly one complete dual-mode IMG was then built;
no second complete build was performed. VM testing and review of Sway's upstream
`swaynag` implementation then exposed an asynchronous Retry-button race: a
dismiss-on-click button could reopen the prompt before the bounded retry had
finished. The launcher now keeps the fixed prompt visible, monitors only the
root-owned mode/status files, and closes it automatically on connection or an
explicit Offline transition. All configuration tests were rerun, then
`build/fix-wifi-retry.sh` replaced only the validated root-owned
`/usr/local/libexec/4tw-online` in the existing IMG. This targeted file update
did not reassemble the image or download packages. The full real-image verifier
was repeated afterward, including filesystem, signed-boot, policy, copied-FAT
write and checksum checks. The pre-correction Windows image is retained under
`artifacts/pre-wifi-retry-monitor-fix-2026-09-08/`; the corrected Windows export
independently matched the final native SHA-256.

Artifact export uses one Windows `Copy-Item` from the WSL UNC path after native
verification. Small logs/checksums are synchronized automatically, but the
sparse IMG is not. The launcher copies under a `.partial` name, rehashes the
complete Windows file, and publishes the final name only on a checksum match.

This is a normal writable USB installation, not a RAM-root BCLD clone. Firefox login/profile state persists. Transient directories, logging and browser cache use RAM. There is no swap, automatic package-update timer, desktop workflow or normal administrative login.

The dual-mode change keeps one Ubuntu installation. GRUB reads the optional
`4TW-CONFIG/4tw-boot.cfg`, validates only `online` or `offline`, presents both
choices for five seconds and passes one fixed kernel mode. Online starts the
existing Firefox kiosk after bounded Wi-Fi setup. Offline stops NetworkManager,
chrony and automatic timezone lookup, mounts only the 4 GiB FAT32
`4TW-WRITING`, and starts FocusWriter with its New/Open/Save dialogs intact.
FocusWriter 1.9.0 has a five-minute emergency recovery cache, not ordinary
timed document autosave; that cache is persistent and Ctrl+S remains necessary.

The power changes are limited to safe internal-panel DRM selection, normal NVIDIA runtime PM, modern CPU EPP/pstate preferences, conservative USB autosuspend exclusions, reduced Firefox recovery writes, and masking clearly unnecessary maintenance timers/services. See `POWER-OPTIMISATION.md` for the exact policy and hardware checklist.

The final image includes the isolated timezone/RTC design. Windows owns its
local-wall-clock RTC; 4TW-OS has no active Chrony RTC directive, RTC device
permission, hardware-clock save service or `/etc/adjtime` maintenance state.
The boot helper imports RTC -> Linux system clock only after applying
manual/last-known/UTC zoneinfo. `timezone=auto` uses `/var/lib/4tw/timezone`
immediately and the NetworkManager-triggered provider makes at most one bounded
HTTPS request. A valid manual IANA value bypasses the provider. Full details are
in `TIMEZONE.md`.
