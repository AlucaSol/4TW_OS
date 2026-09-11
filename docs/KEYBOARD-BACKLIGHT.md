# Acer keyboard backlight

This source tree is ready to use a keyboard-backlight device exposed through
Linux's standard LED class. The change is intentionally conditional because
the WSL build host cannot inspect the Acer's ACPI, WMI, LED or input devices.
It has **not** been included in a new IMG yet.

## Runtime design

- The Ubuntu 26.04 rootfs already contains the signed, in-tree `acer_wmi`
  module. No replacement module, MOK, Acer GUI, tray or new package is added.
- `/usr/local/sbin/4tw-keyboard-backlight` dynamically examines
  `/sys/class/leds`. It prefers the kernel-standard `:kbd_backlight` name,
  recognises zoned and conservative legacy keyboard-light names, and ignores
  LCD backlights, Caps Lock, Num Lock, mail and other LEDs.
- The helper accepts only `up`, `down`, `off` or read-only `status`. Only exact
  `up` and `down` invocations are permitted to the kiosk account through sudo.
  The command line cannot select a path or numeric value.
- `/usr/local/bin/4tw-keyboard-brightness` calls that helper and reuses Mako's
  five-second overlay. It displays `Keyboard: Off`, a percentage, or
  `Keyboard backlight unavailable`.
- Shared `/etc/4tw/sway.conf` binds `XF86KbdBrightnessDown` and
  `XF86KbdBrightnessUp`, so the same controls apply above Firefox and
  FocusWriter. Plain F11/F12 are not repurposed; their pre-existing kiosk
  no-op bindings remain unchanged. The separate Ctrl+Alt+Left/Right LCD
  controls also remain unchanged.
- `keyboard_backlight=off` is the default in the Windows-readable `4tw.cfg`.
  It writes zero only after finding a recognised usable LED. `keep` skips the
  startup write. This CONFIG change does not require a rebuild after an image
  containing the feature has been flashed.

The existing rootfs does not contain `brightnessctl`, and it is not needed:
the fixed helper uses the same LED sysfs ABI directly. In a normal Ubuntu
diagnostic environment, `brightnessctl --class=leds --list` can enumerate LED
devices separately from its default display-backlight class.

## Why support remains conditional

Current upstream `acer-wmi` recognises Acer WMI event `0x84` as an automatic
keyboard-light toggle and deliberately marks it firmware-handled. It does not
provide a general Acer RGB keyboard brightness interface. Linux nevertheless
may expose this laptop's lighting through firmware, HID or another in-tree
driver as a standard LED. Only the physical laptop can establish which path
the Nitro V16S AI uses.

If `/sys/class/leds` has no recognised keyboard-light device, 4TW-OS makes no
vendor-specific WMI or embedded-controller write. Linuwu-Sense, AcerSense and
NitroSense-Linux remain possible investigation targets only after recording
the actual model identifier and diagnostics. They are not installed here;
an out-of-tree module would require exact-model review plus Secure Boot module
signing and must not be adopted merely by disabling Secure Boot.

## Fixed diagnostic

For support work, the root-owned command below prints only hardware facts and
accepts no free-form argument:

```text
/usr/local/sbin/4tw-keyboard-backlight status
```

It reports whether `acer_wmi` is loaded, every LED class entry, input devices
advertising `KEY_KBDILLUMTOGGLE`, `KEY_KBDILLUMDOWN` or `KEY_KBDILLUMUP`, and
the selected keyboard LED's current and maximum levels. It does not expose a
terminal in the kiosk. Run it only through an administrative/live-USB support
session when collecting diagnostics.

If the keys still do not work, boot a normal Ubuntu live environment and run:

```text
sudo libinput debug-events --show-keycodes
```

Press Fn+F11 and Fn+F12 once each and record the device and event names. If
that tool reports nothing, use `sudo evtest` when available, select the Acer
WMI or keyboard input device identified by the fixed report, and repeat. This
distinguishes dedicated keyboard-illumination events from ordinary F11/F12 and
from LCD `KEY_BRIGHTNESSDOWN`/`KEY_BRIGHTNESSUP` events without weakening the
kiosk image.

## Physical Acer checklist after the next combined IMG build

1. Keep `keyboard_backlight=off` in the flashed USB's `4tw.cfg` and boot with
   Secure Boot enabled.
2. Confirm the keyboard light is Off at startup.
3. Press Fn+F12 and confirm keyboard illumination increases without changing
   the LCD.
4. Press Fn+F11 repeatedly and confirm illumination reaches Off without
   wrapping.
5. Confirm Ctrl+Alt+Left/Right still change only LCD brightness.
6. Repeat the illumination checks in Offline Typewriter mode.
7. If any check fails, collect the fixed status report and exact input events
   above. Do not install a third-party driver until the model-specific result
   and Secure Boot implications have been reviewed.

None of these physical checks is claimed as passed by WSL static validation.
