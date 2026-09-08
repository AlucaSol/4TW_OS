#!/usr/bin/python3
"""Build-only Firefox test using its built-in Marionette protocol.

The temporary profile and debugging arguments never enter the shipped image.
No WebDriver packages, extensions, certificate bypasses or browser patches.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

root, artifacts = map(Path, sys.argv[1:])
profile = root / "home/kiosk/.mozilla/4tw-build-smoke"
profile.mkdir(mode=0o700)
os.chown(profile, 1000, 1000)
subprocess.run(["chroot", str(root), "/usr/sbin/runuser", "-u", "kiosk", "--", "/usr/bin/test",
                "-w", "/home/kiosk/.mozilla/4tw-build-smoke"], check=True)
log = (artifacts / "firefox-smoke.log").open("w")
process = subprocess.Popen([
    "chroot", str(root), "/usr/sbin/runuser", "-u", "kiosk", "--", "/usr/bin/env",
    "MOZ_HEADLESS=1", "MOZ_ENABLE_WAYLAND=1", "XDG_RUNTIME_DIR=/run/4tw-sway-test", "XDG_CACHE_HOME=/run/4tw-sway-test/cache",
    "/usr/bin/firefox", "--headless", "--kiosk", "--no-remote", "--marionette", "--remote-allow-system-access",
    "--profile", "/home/kiosk/.mozilla/4tw-build-smoke", "https://4thewords.com/",
], stdout=log, stderr=subprocess.STDOUT, start_new_session=True, cwd=root)
connection = None
counter = 0
results = {}


def receive():
    header = b""
    while not header.endswith(b":"):
        chunk = connection.recv(1)
        if not chunk:
            raise RuntimeError("Marionette disconnected")
        header += chunk
    count = int(header[:-1])
    data = b""
    while len(data) < count:
        data += connection.recv(count - len(data))
    return json.loads(data)


def command(name, params=None):
    global counter
    counter += 1
    data = json.dumps([0, counter, name, params or {}]).encode()
    connection.sendall(str(len(data)).encode() + b":" + data)
    response = receive()
    if response[2]:
        raise RuntimeError(json.dumps(response[2]))
    value = response[3]
    return value.get("value", value) if isinstance(value, dict) else value


def script(code):
    return command("WebDriver:ExecuteScript", {"script": code, "args": [], "newSandbox": False})


def document_state():
    command("Marionette:SetContext", {"value": "chrome"})
    return script("return {url:gBrowser.currentURI.spec,document:gBrowser.selectedBrowser.documentURI.spec,tabs:gBrowser.tabs.length};")


def navigation_was_blocked(state):
    # Firefox may either show its blockedByPolicy error document or cancel the
    # request before replacing the approved page. Both are safe; an external
    # document or an extra tab is never accepted.
    document = state["document"]
    return state["tabs"] == 1 and (
        "blockedByPolicy" in document or document.startswith("https://4thewords.com/")
    )


try:
    for attempt in range(60):
        if process.poll() is not None:
            raise RuntimeError("Firefox exited; see firefox-smoke.log")
        try:
            connection = socket.create_connection(("127.0.0.1", 2828), timeout=1)
            break
        except OSError:
            time.sleep(0.5)
    if connection is None:
        raise RuntimeError("Marionette did not become ready")
    connection.settimeout(60)
    receive()
    command("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {"acceptInsecureCerts": False, "pageLoadStrategy": "eager"}}})
    command("WebDriver:SetTimeouts", {"pageLoad": 30000, "script": 15000})
    command("Marionette:SetContext", {"value": "chrome"})
    results["policies"] = script("return {status:Services.policies.status,expectedActive:Ci.nsIEnterprisePolicies.ACTIVE,active:Services.policies.getActivePolicies()};")
    assert results["policies"]["status"] == results["policies"]["expectedActive"], results["policies"]
    expected = json.loads((root / "etc/firefox/policies/policies.json").read_text())["policies"]
    assert set(expected) <= set(results["policies"]["active"]), set(expected) - set(results["policies"]["active"])
    results["kiosk"] = script("return {kiosk:Services.appinfo.isInSafeMode === false && window.fullScreen, tabs:gBrowser.tabs.length};")
    assert results["kiosk"]["tabs"] == 1
    for attempt in range(30):
        state = document_state()
        if state["document"].startswith("https://4thewords.com/"):
            break
        time.sleep(1)
    results["initial_document"] = state
    assert state["tabs"] == 1, state
    # Network success is reported separately from local policy success.
    results["site_document_loaded"] = state["document"].startswith("https://4thewords.com/")
    command("Marionette:SetContext", {"value": "content"})
    if results["site_document_loaded"]:
        results["site_title"] = script("return document.title;")
        # Trigger an ordinary link click in the current document.
        script("const a=document.createElement('a'); a.href='https://example.com/4tw-link-test'; a.textContent='test'; document.body.appendChild(a); a.click();")
        for attempt in range(20):
            state = document_state()
            if "blockedByPolicy" in state["document"]:
                break
            time.sleep(0.25)
        results["external_clicked_link"] = state
        assert navigation_was_blocked(state), state
    command("Marionette:SetContext", {"value": "content"})
    try:
        command("WebDriver:Navigate", {"url": "https://example.org/4tw-direct-test"})
    except RuntimeError as error:
        results["navigation_error"] = str(error)
    for attempt in range(20):
        state = document_state()
        if "blockedByPolicy" in state["document"]:
            break
        time.sleep(0.25)
    results["external_direct"] = state
    assert navigation_was_blocked(state), state
    results["passed"] = True
    print(json.dumps(results, indent=2))
finally:
    (artifacts / "browser-smoke.json").write_text(json.dumps(results, indent=2) + "\n")
    if connection:
        try:
            command("Marionette:Quit", {"flags": ["eForceQuit"]})
        except (OSError, RuntimeError):
            pass
        connection.close()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, 15)
        process.wait(timeout=10)
    log.close()
    # This is an exclusively test-created profile, never the runtime profile.
    assert profile == root / "home/kiosk/.mozilla/4tw-build-smoke"
    shutil.rmtree(profile)
