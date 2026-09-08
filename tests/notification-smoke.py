#!/usr/bin/python3
"""Build-only Wayland/Mako test, launched inside a temporary D-Bus session."""
import json
import os
from pathlib import Path
import subprocess
import time

runtime = Path(os.environ["XDG_RUNTIME_DIR"])
config = runtime / "sway.conf"
config.write_text("xwayland disable\noutput * resolution 1280x800\n")
log = (runtime / "sway.log").open("w")
sway = subprocess.Popen(["/usr/bin/sway", "--config", str(config)], stdout=log, stderr=subprocess.STDOUT)
mako = None
try:
    for attempt in range(50):
        sockets = [p for p in runtime.glob("wayland-*") if not p.name.endswith(".lock")]
        if sockets:
            os.environ["WAYLAND_DISPLAY"] = sockets[0].name
            break
        if sway.poll() is not None:
            raise RuntimeError((runtime / "sway.log").read_text())
        time.sleep(0.1)
    with (runtime / "mako.log").open("w") as makolog:
        mako = subprocess.Popen(["/usr/bin/mako", "--config", "/etc/4tw/mako.conf"], stdout=makolog, stderr=subprocess.STDOUT)
    time.sleep(1)
    if mako.poll() is not None:
        raise RuntimeError((runtime / "mako.log").read_text())
    subprocess.run(["/usr/local/bin/4tw-battery"], check=True)
    result = subprocess.run(["/usr/bin/makoctl", "list"], text=True, capture_output=True)
    print("Immediate notification list:", result.stdout, result.stderr, flush=True)
    assert result.returncode == 0
    time.sleep(6)
    result = subprocess.run(["/usr/bin/makoctl", "list"], text=True, capture_output=True)
    print("After timeout:", result.stdout, result.stderr, flush=True)
finally:
    if mako is not None and mako.poll() is None:
        mako.terminate()
        mako.wait(timeout=5)
    sway.terminate()
    sway.wait(timeout=5)
    log.close()
