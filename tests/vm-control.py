#!/usr/bin/python3
import json
from pathlib import Path
import socket
import sys
import time

project, action = Path(sys.argv[1]).resolve(), sys.argv[2]
allowed = {"status", "screenshot", "battery", "brightness", "escape", "shutdown", "powerbutton", "quit", "battery-series", "brightness-series"}
if action not in allowed:
    raise SystemExit(2)
connection = socket.socket(socket.AF_UNIX)
connection.connect(str(project / ".work/vm.qmp"))
handle = connection.makefile("rb")
def call(command, arguments=None):
    connection.sendall((json.dumps({"execute": command, "arguments": arguments or {}}) + "\n").encode())
    while True:
        response = json.loads(handle.readline())
        if "error" in response:
            raise RuntimeError(response["error"])
        if "return" in response:
            return response["return"]
json.loads(handle.readline())
call("qmp_capabilities")
if action == "status":
    print(json.dumps(call("query-status")))
elif action == "screenshot":
    name = sys.argv[3] if len(sys.argv) == 4 else "vm-screen.png"
    assert Path(name).name == name and name.endswith(".png")
    print(call("screendump", {"filename": str(project / "artifacts" / name), "format": "png"}))
elif action in {"battery", "brightness", "escape", "shutdown", "battery-series", "brightness-series"}:
    control = action.removesuffix("-series")
    keys = {"battery": ["ctrl", "alt", "b"], "brightness": ["ctrl", "alt", "right"],
            "escape": ["alt", "f4"], "shutdown": ["ctrl", "alt", "delete"]}[control]
    print(call("send-key", {"keys": [{"type": "qcode", "data": key} for key in keys], "hold-time": 100}))
    if action.endswith("-series"):
        for index in range(1, 8):
            time.sleep(1)
            call("screendump", {"filename": str(project / "artifacts" / f"vm-{control}-{index}s.png"), "format": "png"})
elif action == "powerbutton":
    print(call("system_powerdown"))
elif action == "quit":
    print(call("quit"))
connection.close()
