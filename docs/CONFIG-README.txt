4TW-OS USB configuration

Edit 4tw.cfg on THIS FAT32 partition using Windows Notepad.
Do not change the key names. Do not add quotes around values.

wifi_ssid_b64 and wifi_psk_b64 are UTF-8 Base64 text, NOT encryption.
Anyone with this USB can decode them. Keep credentials out of source control.
Both may be left empty, but then Wi-Fi will not connect.

start_url controls the one page Firefox opens. It must be an http:// or
https:// URL with a valid hostname. HTTPS is recommended. A missing or invalid
value safely falls back to https://4thewords.com/ and is reported in the boot
log.

site_lock=auto automatically limits top-level Firefox navigation to the exact
start_url hostname, its subdomains, and any comma-separated hostnames in
allowed_extra_domains. Do not include schemes, paths or wildcards in the extra
domain list. Invalid entries are ignored and reported without stopping boot.

site_lock=off removes the domain WebsiteFilter but retains Firefox kiosk mode
and all other browser/Sway restrictions. Use it only when you intentionally do
not want domain filtering. Examples:

start_url=https://4thewords.com/
site_lock=auto
allowed_extra_domains=

start_url=https://example.com/
site_lock=auto
allowed_extra_domains=accounts.example.com,cdn.example.net

These three settings take effect on the next boot. Changing them does not
require rebuilding the IMG or reflashing the USB.

timezone=auto uses the last successful timezone immediately, then makes one
short HTTPS request to ipapi.co after Wi-Fi is available. The public IP is
necessarily visible to that service. A VPN/proxy can produce the wrong zone.
Set a validated IANA name such as timezone=Australia/Darwin for a manual
override; manual mode makes no timezone-provider request. Restore auto after
travel if you want detection again. Windows owns the laptop hardware clock;
4TW-OS reads it at boot but never writes or synchronises it.

keyboard_backlight=off turns off a detected standard Linux keyboard-backlight
LED at startup. The keyboard illumination-up key can turn it on again. Use
keyboard_backlight=keep to leave the firmware's existing state unchanged.
This setting is ignored safely when the hardware exposes no recognised LED.

The separate 4tw-boot.cfg controls only the boot menu's automatic choice:

set default_mode="online"

or:

set default_mode="offline"

Both Online and Offline remain manually selectable for five seconds. Missing
or invalid values safely default to Online. No rebuild or reflash is required.

Offline Typewriter documents live on the separate FAT32 volume 4TW-WRITING.
FocusWriter defaults to plain .txt in its Drafts folder. Press Ctrl+S for normal
saves; its emergency recovery cache is not ordinary timed document autosave.

In Online mode, Ctrl+Alt+R completely restarts Firefox at start_url while
preserving login cookies and site data. F5 remains an ordinary page refresh.
Use Ctrl+Alt+Delete for clean shutdown before unplugging.
If Windows offers to format an unfamiliar Linux or EFI partition, CANCEL.
Never format the Linux system or EFI partition.
