#!/usr/bin/python3
"""Build-only headless Sway test of the packaged FocusWriter main window."""
import configparser
import json
import os
from pathlib import Path
import subprocess
import time

runtime = Path(os.environ["XDG_RUNTIME_DIR"])
config = runtime / "focuswriter-sway.conf"
config.write_text(
    "xwayland disable\n"
    "output * resolution 1280x800\n"
    'for_window [app_id="focuswriter" title="^FocusWriter$"] fullscreen enable\n',
    encoding="utf-8")
settings_folder = runtime / "config/GottCode"
settings_folder.mkdir(parents=True, exist_ok=True)
settings = configparser.ConfigParser()
settings.optionxform = str
settings["Save"] = {"DefaultFormat": "txt", "Location": "/writing/Drafts"}
settings["Window"] = {"Fullscreen": "true"}
with (settings_folder / "FocusWriter.conf").open("w", encoding="utf-8") as handle:
    settings.write(handle, space_around_delimiters=False)
document = runtime / "FocusWriter-smoke.txt"
document.write_text("4TW-OS build-only test\n", encoding="utf-8")
(runtime / "data").mkdir(exist_ok=True)
log = (runtime / "focuswriter-smoke.log").open("w")
sway = subprocess.Popen(["/usr/bin/sway", "--config", str(config)], stdout=log, stderr=subprocess.STDOUT)
focuswriter = None


def containers(node):
    yield node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from containers(child)


try:
    for attempt in range(60):
        wayland = sorted(path for path in runtime.glob("wayland-*") if not path.name.endswith(".lock"))
        ipc = sorted(runtime.glob("sway-ipc.*.sock"))
        if wayland and ipc:
            break
        if sway.poll() is not None:
            raise RuntimeError((runtime / "focuswriter-smoke.log").read_text(errors="replace"))
        time.sleep(0.1)
    else:
        raise RuntimeError("Sway did not expose its build-test sockets")
    environment = os.environ.copy()
    environment.update({
        "WAYLAND_DISPLAY": wayland[0].name,
        "SWAYSOCK": str(ipc[0]),
        "QT_QPA_PLATFORM": "wayland",
        "XDG_CONFIG_HOME": str(runtime / "config"),
        "XDG_DATA_HOME": str(runtime / "data"),
    })
    focuswriter = subprocess.Popen(["/usr/bin/focuswriter", str(document)], env=environment,
                                   stdout=log, stderr=subprocess.STDOUT)
    main = None
    for attempt in range(100):
        if focuswriter.poll() is not None:
            raise RuntimeError("FocusWriter exited during its Wayland smoke test")
        result = subprocess.run(["/usr/bin/swaymsg", "-s", str(ipc[0]), "-t", "get_tree", "-r"],
                                text=True, capture_output=True, check=True)
        tree = json.loads(result.stdout)
        matches = [node for node in containers(tree) if node.get("app_id") == "focuswriter"]
        if matches:
            main = matches[0]
            break
        time.sleep(0.1)
    if main is None:
        raise RuntimeError("FocusWriter did not create a native Wayland window")
    assert main.get("name") == "FocusWriter", main
    assert main.get("fullscreen_mode") == 1, main
    print(json.dumps({"passed": True, "app_id": main.get("app_id"), "title": main.get("name"),
                      "fullscreen_mode": main.get("fullscreen_mode")}, indent=2))
finally:
    if focuswriter is not None and focuswriter.poll() is None:
        focuswriter.terminate()
        try:
            focuswriter.wait(timeout=5)
        except subprocess.TimeoutExpired:
            focuswriter.kill()
            focuswriter.wait(timeout=5)
    if sway.poll() is None:
        sway.terminate()
        sway.wait(timeout=5)
    log.close()
