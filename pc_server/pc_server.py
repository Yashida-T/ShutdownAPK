"""
Shutdown Scheduler - PC side (Windows).

    pip install flask
    python pc_server.py

Run this on the PC you want to control. The phone app finds it by PC name or
IP address. The first time a phone connects, a Yes/No box pops up on this PC;
after you click Yes the phone is remembered (no passwords or tokens to type).

Supported actions: shutdown, sleep, logout (each can be scheduled or run now).

Note: "sleep" uses Windows' SetSuspendState, which hibernates instead of
sleeping when hibernation is enabled. To get true sleep, run this once in an
administrator Command Prompt:   powercfg -h off
"""

import ctypes
import json
import os
import secrets
import socket
import subprocess
import threading
from datetime import datetime, timedelta
from pathlib import Path

from flask import Flask, jsonify, request

HTTP_PORT = 5000
MAX_SECONDS = 7 * 24 * 3600
ACTIONS = ("shutdown", "sleep", "logout")
APP_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "ShutdownScheduler"
DEVICES_FILE = APP_DIR / "paired_devices.json"

app = Flask(__name__)
lock = threading.Lock()
pair_lock = threading.Lock()
state = {"action": None, "target": None, "timer": None}


# ---------- paired devices ----------
def load_devices():
    try:
        return json.loads(DEVICES_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_devices(devices):
    APP_DIR.mkdir(parents=True, exist_ok=True)
    DEVICES_FILE.write_text(json.dumps(devices))


devices = load_devices()  # token -> device name


def ask_pc_owner(name):
    """Show a Yes/No box on the PC (Windows)."""
    MB_YESNO, MB_ICONQUESTION, MB_TOPMOST = 0x4, 0x20, 0x40000
    res = ctypes.windll.user32.MessageBoxW(
        0,
        f'Allow "{name}" to control shutdown, sleep and log out on this PC?',
        "Shutdown Scheduler",
        MB_YESNO | MB_ICONQUESTION | MB_TOPMOST,
    )
    return res == 6  # IDYES


# ---------- auth ----------
OPEN_PATHS = ("/api/hello", "/api/pair")


@app.before_request
def check_auth():
    if request.path.startswith("/api/") and request.path not in OPEN_PATHS:
        if request.headers.get("X-Token", "") not in devices:
            return jsonify(error="Not paired"), 401


@app.get("/api/hello")
def hello():
    return jsonify(app="shutdown-scheduler", name=socket.gethostname(), port=HTTP_PORT)


@app.post("/api/pair")
def pair():
    data = request.get_json(silent=True) or {}
    name = str(data.get("name", "Unknown phone"))[:40]
    with pair_lock:  # one prompt at a time
        if not ask_pc_owner(name):
            return jsonify(error="Pairing was declined on the PC"), 403
        token = secrets.token_urlsafe(24)
        devices[token] = name
        save_devices(devices)
    return jsonify(token=token, pc=socket.gethostname())


# ---------- actions ----------
def run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        return False, str(e)
    return r.returncode == 0, (r.stderr or r.stdout).strip()


def perform(action):
    if action == "sleep":
        run(["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"])
    elif action == "logout":
        run(["shutdown", "/l"])


def fire(action):
    with lock:
        state.update(action=None, target=None, timer=None)
    perform(action)


def cancel_locked():
    """Cancel anything pending. Returns True if something was scheduled."""
    target = state["target"]
    had = target is not None and target > datetime.now()
    if state["timer"] is not None:
        state["timer"].cancel()
    ok, _ = run(["shutdown", "/a"])  # abort a pending Windows shutdown
    state.update(action=None, target=None, timer=None)
    return had or ok


def payload_locked():
    now = datetime.now()
    target = state["target"]
    if target is not None and target <= now:
        state.update(action=None, target=None, timer=None)
        target = None
    return {
        "pc": socket.gethostname(),
        "now": now.isoformat(timespec="seconds"),
        "action": state["action"],
        "remaining": int((target - now).total_seconds()) if target else None,
        "target_text": target.strftime("%I:%M %p, %d %b") if target else None,
    }


# ---------- API ----------
@app.get("/api/status")
def status():
    with lock:
        return jsonify(payload_locked())


@app.post("/api/schedule")
def schedule():
    data = request.get_json(silent=True) or {}
    action = str(data.get("action", "shutdown"))
    if action not in ACTIONS:
        return jsonify(error="Unknown action"), 400
    try:
        seconds = int(data.get("seconds", 0))
    except (TypeError, ValueError):
        return jsonify(error="Invalid time"), 400
    if seconds < 0 or seconds > MAX_SECONDS:
        return jsonify(error="Time must be within 7 days"), 400
    seconds = max(seconds, 1)

    with lock:
        cancel_locked()  # replace any previous schedule
        timer = None
        if action == "shutdown":
            ok, msg = run(["shutdown", "/s", "/t", str(seconds)])
            if not ok:
                return jsonify(error=msg or "shutdown command failed"), 500
        else:
            timer = threading.Timer(seconds, fire, args=(action,))
            timer.daemon = True
            timer.start()
        state.update(
            action=action,
            target=datetime.now() + timedelta(seconds=seconds),
            timer=timer,
        )
        return jsonify(payload_locked())


@app.post("/api/cancel")
def cancel():
    with lock:
        cancelled = cancel_locked()
    return jsonify(ok=True, cancelled=bool(cancelled))


if __name__ == "__main__":
    print(f"Shutdown Scheduler running as '{socket.gethostname()}' on port {HTTP_PORT}.")
    print("Open the phone app and connect to this PC's name or IP address.")
    print("If Windows Firewall asks, allow Python on PRIVATE networks.")
    app.run(host="0.0.0.0", port=HTTP_PORT, threaded=True)
