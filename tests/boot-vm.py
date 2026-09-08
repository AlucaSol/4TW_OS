#!/usr/bin/python3
"""Start a headless UEFI/Secure Boot VM using a disposable disk snapshot."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

project = Path(sys.argv[1]).resolve()
work, artifacts = project / ".work", project / "artifacts"
image = artifacts / "4TW-OS_RELEASE.img"
assert image.is_file() and not image.is_symlink()
qmp = work / "vm.qmp"
if qmp.exists():
    raise SystemExit("VM control socket already exists; inspect existing VM first")
variables = work / "OVMF_VARS-test.fd"
shutil.copyfile("/usr/share/OVMF/OVMF_VARS_4M.ms.fd", variables)
command = [
    "/usr/bin/qemu-system-x86_64", "-name", "4tw-release-verification",
    "-machine", "q35,smm=on", "-accel", "tcg", "-cpu", "max", "-m", "4096", "-smp", "2",
    "-global", "driver=cfi.pflash01,property=secure,value=on",
    "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd",
    "-drive", f"if=pflash,format=raw,unit=1,file={variables}",
    "-device", "qemu-xhci", "-drive", f"if=none,id=stick,format=raw,snapshot=on,file={image}",
    "-device", "usb-storage,drive=stick,bootindex=1", "-device", "virtio-vga", "-vga", "none",
    "-display", "none", "-nic", "none", "-serial", f"file:{artifacts / 'vm-serial.log'}",
    "-qmp", f"unix:{qmp},server=on,wait=off", "-no-reboot",
]
(artifacts / "vm-command.json").write_text(json.dumps(command, indent=2) + "\n")
with (artifacts / "vm-qemu.log").open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
(work / "vm.pid").write_text(str(process.pid))
for attempt in range(30):
    if process.poll() is not None:
        raise SystemExit("QEMU exited; inspect vm-qemu.log")
    if qmp.exists():
        print(f"VM started, PID {process.pid}; only snapshot IMG and copied firmware variables are writable.")
        break
    time.sleep(0.2)
