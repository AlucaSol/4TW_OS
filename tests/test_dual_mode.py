#!/usr/bin/python3
"""Unit tests for mode selection, fixed actions, document choice and GRUB."""
from datetime import datetime
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project / "rootfs-overlay/usr/local/lib/4tw"))
import appliance


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("PASS: " + message)


check(appliance.boot_mode("quiet 4tw.mode=online") == "online", "Online kernel mode accepted")
check(appliance.boot_mode("quiet 4tw.mode=offline") == "offline", "Offline kernel mode accepted")
for malformed in ("", "4tw.mode=other", "4tw.mode=offline 4tw.mode=offline",
                  "4tw.mode=offline 4tw.mode=online"):
    check(appliance.boot_mode(malformed) == "online", "malformed/ambiguous mode safely falls back Online")


class Result:
    returncode = 0


commands = []
def successful_runner(command, **kwargs):
    commands.append((command, kwargs))
    return Result()


with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    connection = folder / "4tw-wifi.nmconnection"
    connection.write_text("builder-created\n")
    check(appliance.connect_wifi(connection, successful_runner), "bounded fixed Wi-Fi attempt succeeds")
    check([item[0] for item in commands] == [
        ["/usr/bin/nmcli", "networking", "on"],
        ["/usr/bin/nmcli", "radio", "wifi", "on"],
        ["/usr/bin/nmcli", "connection", "load", str(connection)],
        ["/usr/bin/nmcli", "--wait", "12", "connection", "up", "uuid", appliance.NETWORK_UUID],
    ], "Wi-Fi retry invokes only fixed NetworkManager commands")
    check(all(not kwargs.get("shell", False) and kwargs["timeout"] <= 15 for _, kwargs in commands),
          "Wi-Fi commands do not use a shell and all have short timeouts")

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    status = folder / "writing-status"
    mode = folder / "mode"
    commands.clear()
    check(appliance.enter_offline(successful_runner, lambda path: path == "/writing", mode, status),
          "Offline transition reports mounted writing storage")
    check(mode.read_text().strip() == "offline" and status.read_text().strip() == "ready",
          "Offline transition writes only fixed runtime state")
    flattened = [command for command, _ in commands]
    check(["/usr/bin/systemctl", "stop", "NetworkManager.service"] in flattened and
          ["/usr/bin/systemctl", "stop", "chrony.service"] in flattened and
          ["/usr/bin/systemctl", "start", "writing.mount"] in flattened,
          "Offline transition stops networking/time sync and mounts only WRITING")

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    (root / "Drafts").mkdir()
    (root / "README.txt").write_text("ignore")
    (root / ".hidden.txt").write_text("ignore")
    (root / "Drafts/.autosave.txt").write_text("ignore")
    (root / "Drafts/older.txt").write_text("old", encoding="utf-8")
    (root / "Drafts/newer.txt").write_text("new", encoding="utf-8")
    os.utime(root / "Drafts/older.txt", ns=(1_000_000_000, 1_000_000_000))
    os.utime(root / "Drafts/newer.txt", ns=(2_000_000_000, 2_000_000_000))
    check(appliance.recent_writing_document(root) == root / "Drafts/newer.txt",
          "most recently modified eligible .txt file wins")
    for path in (root / "Drafts/older.txt", root / "Drafts/newer.txt"):
        path.unlink()
    created = appliance.ensure_writing_document(root, datetime(2026, 9, 8, 21, 7))
    check(created == root / "Drafts/Draft-2026-09-08-2107.txt" and created.is_file(),
          "no-document case creates a real timestamped UTF-8 text file")

refresh = runpy.run_path(str(project / "rootfs-overlay/usr/local/sbin/4tw-refresh-boot"))
grub = refresh["render_grub"]("1111-2222", "vmlinuz-test-generic", "initrd.img-test-generic", "test-password")
check(grub.count("menuentry ") == 2 and 'menuentry "4TW Online" --id online' in grub and
      'menuentry "Offline Typewriter" --id offline' in grub, "GRUB has exactly two manual appliance choices")
check('set default_mode="online"' in grub and 'set default="offline"' in grub and
      'set default="online"' in grub and 'set timeout=5' in grub and 'set timeout_style=menu' in grub,
      "GRUB defaults safely Online, validates Offline, and retains a visible five-second menu")
check(grub.index('source "($twconfig)/4tw-boot.cfg"') < grub.index('set timeout=5'),
      "GRUB reads CONFIG before applying the fixed countdown")
check(grub.count("4tw.mode=online") == 1 and grub.count("4tw.mode=offline") == 1,
      "each boot choice passes exactly one correct kernel mode")
if shutil.which("grub-script-check"):
    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as handle:
        handle.write(grub)
        handle.flush()
        subprocess.run(["grub-script-check", handle.name], check=True)
    print("PASS: generated dual-mode GRUB syntax accepted")

print("Dual-mode helper tests passed.")
