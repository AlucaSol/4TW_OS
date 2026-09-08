# Online and Offline modes

4TW-OS is one Ubuntu installation with one signed Ubuntu boot chain and one
root filesystem. Its five-second boot menu always offers:

- **4TW Online** — starts Wi-Fi and one Firefox kiosk at 4thewords.
- **Offline Typewriter** — leaves Firefox closed, stops networking and network
  time, mounts `4TW-WRITING` at `/writing`, and opens one FocusWriter window.

The menu defaults to Online. To change only the automatic choice, edit
`4TW-CONFIG\4tw-boot.cfg` in Windows Notepad:

```text
set default_mode="online"
```

or:

```text
set default_mode="offline"
```

Both manual choices and the five-second countdown remain. A missing, unreadable
or unsupported value falls back to Online. Changing the file requires neither
an IMG rebuild nor reflashing.

## Offline writing

`4TW-WRITING` is an approximately 4 GiB FAT32 volume readable by Windows and
Linux. FocusWriter starts in fullscreen, defaults to UTF-8 `.txt`, and defaults
Open/Save to `/writing/Drafts`. At startup, the newest eligible `.txt` anywhere
on that volume opens. `README.txt`, hidden/system, lock, temporary and recovery
files are ignored. With no eligible file, a real
`Draft-YYYY-MM-DD-HHMM.txt` is created immediately.

FocusWriter 1.9.0 does **not** perform timed saves to the open file. Its native
five-minute emergency/session-recovery cache is retained persistently on the
Ubuntu root filesystem. Press **Ctrl+S** for normal explicit saves. The launcher
does not use keyboard injection or claim that recovery is ordinary autosave.

New, Open, Save and Save As remain available through FocusWriter itself. There
is no separate file manager, terminal, launcher, panel or browser in Offline
mode. The internal Windows SSD is not mounted.

If Online Wi-Fi fails after its bounded attempt, a fixed Sway prompt offers
Retry Wi-Fi, Offline Typewriter, or Shut Down. Offline is entered in the same
boot only when selected; it is never selected automatically because Wi-Fi
failed.

## Windows access and safe removal

After 4TW-OS has powered off completely, boot Windows and open the removable
volume named `4TW-WRITING`. Files can be copied, renamed and edited normally.
Safely eject the USB before unplugging it. Cancel any Windows request to format
an unfamiliar Linux system or EFI partition.

## Physical Acer checklist

1. Boot without touching the menu; confirm Online starts after about five
   seconds, Wi-Fi connects, and Firefox/4thewords behaves as before.
2. Reboot and choose Offline; confirm networking is unavailable, FocusWriter is
   fullscreen, a Draft exists, Ctrl+S saves it, clean shutdown completes, and
   Windows reads the same file from `4TW-WRITING`.
3. Modify/create a `.txt` in Windows, boot Offline, and confirm the newest
   eligible file opens.
4. Make the configured Wi-Fi unavailable, boot Online, confirm the fixed three
   choices, select Offline, and confirm FocusWriter starts without rebooting.
5. In Offline mode test Ctrl+Alt+B, Ctrl+Alt+Left/Right, Ctrl+Alt+Delete and the
   physical power button.

These physical tests are not claimed as passed until performed on the Acer.
