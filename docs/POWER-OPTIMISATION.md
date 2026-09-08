# Power and USB-write optimisation

This Release keeps the existing Ubuntu 26.04, Sway and Firefox kiosk architecture. It does not use `toram`, a read-only root, a desktop power manager, a proprietary NVIDIA driver, unsafe PCI removal, undervolting, or forced software rendering.

## Exact changes

- At login, `/usr/local/bin/4tw-select-gpu` inspects DRM connectors. Sway receives `WLR_DRM_DEVICES` only when a card is proven to drive the connected eDP/LVDS/DSI internal panel, or when it is the only usable DRM card. A non-NVIDIA internal-panel card is preferred. Ambiguous multi-GPU systems retain wlroots auto-detection rather than using a guessed PCI address.
- Discrete-GPU offload environment variables are cleared. `MOZ_ENABLE_WAYLAND=1` remains enabled, and neither Firefox nor Sway is forced to use software rendering.
- `4tw-power-setup.service` runs one bounded, fixed-purpose helper at boot. NVIDIA display devices and NVIDIA functions in the same PCI slot receive the kernel's normal `power/control=auto` setting. The helper never removes a PCI device or forces it off; active drivers/displays retain the device normally.
- On modern `amd-pstate`, `amd-pstate-epp` or `intel_pstate` CPU policies, the helper selects the standard `powersave` governor when advertised. It selects `balance_power` only when the driver's EPP interface advertises it. Unsupported CPU drivers are left unchanged.
- USB devices receive a two-second normal autosuspend delay only when they are not storage, HID/input or networking devices. This conservatively excludes the boot USB, keyboard/touchpad and Wi-Fi. No global USB autosuspend kernel override or device-specific quirk was added.
- Wi-Fi power saving remains at the driver/NetworkManager default. Stability and typing responsiveness take priority over a marginal additional saving.
- Firefox's normal HTTP disk and offline caches remain disabled. Its cache parent is locked to `/run/user/1000/cache/firefox`, under the RAM-backed runtime directory. The persistent profile stays at `/home/kiosk/.mozilla/4tw`, retaining cookies and site storage. Recovery-state writes are limited to one every five minutes.
- Existing write controls remain: root uses `noatime`; `/tmp` and `/var/tmp` are tmpfs; journald uses `Storage=volatile`; APT update timers and fstrim are disabled; and the image has no swap partition or swapfile.
- Ctrl+Alt+B still shows the temporary battery notification and now adds `dGPU: suspended`, `active` or `unavailable` from the NVIDIA display device's `runtime_status`. It does not guess when the interface is unavailable.
- `/usr/local/bin/4tw-power-status` is a fixed, no-argument maintenance diagnostic. It reports battery data, dGPU state, selected integrated DRM card, CPU policy, sampled Firefox CPU use, load and memory. It is not bound to a key and does not expose a shell.

## Services audited

The following installed units are now masked because they perform unattended maintenance or network work that is unnecessary during a fixed-purpose writing session:

| Unit | Reason |
| --- | --- |
| `dpkg-db-backup.timer` | Avoid periodic package-database backup writes; images are rebuilt for updates. |
| `e2scrub_all.timer`, `e2scrub_reap.service` | Avoid scheduled filesystem scanning/metadata work during kiosk use; clean shutdown and offline image checks remain. |
| `motd-news.timer` | No interactive shell or MOTD exists in the kiosk. |
| `ua-timer.timer`, `ubuntu-advantage.service`, `ua-reboot-cmds.service` | Ubuntu Pro attachment/update work is not used by this appliance. |

APT update timers and `fstrim.timer` were already masked. CUPS/printing, Avahi, Bluetooth, ModemManager, PackageKit, power-profiles-daemon, Whoopsie, SSH, terminal emulators, file managers, display managers and application launchers are not installed. NetworkManager, wpa_supplicant, PipeWire/WirePlumber, time synchronisation, logind and input support remain.

## Measurement and maintenance

There is deliberately no terminal shortcut in the kiosk. From a controlled maintenance environment, the fixed helper is:

```sh
/usr/local/bin/4tw-power-status
```

The underlying instantaneous battery reading is `power_now` in microwatts:

```sh
cat /sys/class/power_supply/BAT*/power_now
```

Divide that value by 1,000,000 for watts. When `power_now` is absent, multiply `current_now` by `voltage_now` and divide by 1,000,000,000,000. Ctrl+Alt+B performs the same guarded calculation without exposing a shell and omits unavailable values.

To inspect NVIDIA runtime state from maintenance Linux:

```sh
grep -H . /sys/bus/pci/devices/*/vendor /sys/bus/pci/devices/*/power/runtime_status /sys/bus/pci/devices/*/power/control
```

For a useful comparison, unplug AC power, use the same brightness and Wi-Fi conditions, wait five minutes after boot, then record at least three readings while the 4thewords page is idle and three while typing. Short instantaneous readings fluctuate; compare medians rather than a single sample.

## Acer hardware smoke test

- [ ] Boot the USB with Secure Boot enabled.
- [ ] Confirm 4thewords loads over the configured Wi-Fi.
- [ ] Log in, shut down cleanly, reboot, and confirm the login persists.
- [ ] Confirm Ctrl+Alt+B shows real battery data and a credible dGPU state.
- [ ] Confirm both brightness shortcuts work.
- [ ] Confirm Ctrl+Alt+Delete and the physical power button shut down cleanly.
- [ ] Record idle battery power draw under controlled conditions.
- [ ] Record typing-session battery power draw under the same conditions.
- [ ] Confirm the NVIDIA dGPU becomes `suspended` while idle when no display requires it.
- [ ] Confirm Firefox remains responsive and 4thewords visuals and audio work.

These hardware checks are not claimed as passed until completed on the Acer. A future `toram` or read-only-root variant remains possible if physical measurements show that the current targeted write reductions are insufficient.
