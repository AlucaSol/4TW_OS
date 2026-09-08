4TW-OS USB configuration

Edit 4tw.cfg on THIS FAT32 partition using Windows Notepad.
Do not change the key names. Do not add quotes around values.

wifi_ssid_b64 and wifi_psk_b64 are UTF-8 Base64 text, NOT encryption.
Anyone with this USB can decode them. Keep credentials out of source control.
Both may be left empty, but then Wi-Fi will not connect.

Only HTTPS start URLs permitted by the built-in allowlist are accepted.
The default is https://4thewords.com/
An invalid configuration fails safely to the default URL without Wi-Fi.

timezone=auto uses the last successful timezone immediately, then makes one
short HTTPS request to ipapi.co after Wi-Fi is available. The public IP is
necessarily visible to that service. A VPN/proxy can produce the wrong zone.
Set a validated IANA name such as timezone=Australia/Darwin for a manual
override; manual mode makes no timezone-provider request. Restore auto after
travel if you want detection again. The hardware clock always remains UTC.

Use Ctrl+Alt+Delete for clean shutdown before unplugging.
If Windows offers to format another partition on this USB, CANCEL.
Never format the Linux system or EFI partition.
