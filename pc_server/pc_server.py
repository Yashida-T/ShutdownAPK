"""
Shutdown Scheduler - PC side (Windows).

Runs quietly in the system tray, starts with Windows, and lets the phone app
schedule a shutdown, sleep or log out.

    pip install flask pystray pillow
    python pc_server.py

or build a standalone .exe with build_exe.bat.

The phone app finds this PC by name or IP address. The first time a phone
connects, a Yes/No box pops up on this PC; after you click Yes the phone is
remembered (no passwords or tokens to type).

Note: "sleep" uses Windows' SetSuspendState, which hibernates instead of
sleeping when hibernation is enabled. For true sleep, run once in an
administrator Command Prompt:   powercfg -h off
"""

import ctypes
import json
import logging
import os
import secrets
import socket
import subprocess
import sys
import threading
from datetime import datetime, timedelta
from pathlib import Path

from flask import Flask, jsonify, request

# A windowed (no-console) exe has no stdout/stderr; give it somewhere harmless to write.
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w")

IS_WINDOWS = sys.platform == "win32"
HTTP_PORT = 5000
MAX_SECONDS = 7 * 24 * 3600
ACTIONS = ("shutdown", "sleep", "logout")
APP_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "ShutdownScheduler"
DEVICES_FILE = APP_DIR / "paired_devices.json"
FIRST_RUN_FILE = APP_DIR / "first_run_done"

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


def message_box(text, flags):
    """Show a Windows message box on top of everything. Returns the button id."""
    return ctypes.windll.user32.MessageBoxW(0, text, "Shutdown Scheduler", flags | 0x40000)


def info_box(text):
    message_box(text, 0x40)  # MB_ICONINFORMATION


def ask_pc_owner(name):
    """Show a Yes/No box on the PC (Windows)."""
    res = message_box(
        f'Allow "{name}" to control shutdown, sleep and log out on this PC?',
        0x4 | 0x20,  # MB_YESNO | MB_ICONQUESTION
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
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            creationflags=0x08000000 if IS_WINDOWS else 0,  # CREATE_NO_WINDOW
        )
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


# ---------- start with Windows ----------
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_NAME = "ShutdownScheduler"


def startup_command():
    if getattr(sys, "frozen", False):  # running as the built .exe
        return f'"{sys.executable}"'
    pyw = Path(sys.executable).with_name("pythonw.exe")  # no console window
    exe = pyw if pyw.exists() else Path(sys.executable)
    return f'"{exe}" "{Path(__file__).resolve()}"'


def autostart_enabled():
    if not IS_WINDOWS:
        return False
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, RUN_NAME)
            return True
    except OSError:
        return False


def set_autostart(enabled):
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            winreg.SetValueEx(key, RUN_NAME, 0, winreg.REG_SZ, startup_command())
        else:
            try:
                winreg.DeleteValue(key, RUN_NAME)
            except OSError:
                pass


# ---------- tray icon ----------
def make_icon_image():
    from PIL import Image, ImageDraw

    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((4, 4, 60, 60), fill=(59, 130, 246, 255))
    d.arc((18, 18, 46, 46), start=-60, end=240, fill="white", width=5)
    d.line((32, 14, 32, 32), fill="white", width=5)
    return img


def run_tray():
    import pystray

    def toggle_autostart(icon, item):
        set_autostart(not autostart_enabled())

    def forget_phones(icon, item):
        devices.clear()
        save_devices(devices)
        info_box("All phones were forgotten. Each phone will ask for approval again.")

    def quit_app(icon, item):
        icon.stop()

    menu = pystray.Menu(
        pystray.MenuItem(f"Shutdown Scheduler - {socket.gethostname()}", None, enabled=False),
        pystray.MenuItem(lambda item: f"Address: {local_ip()}", None, enabled=False),
        pystray.MenuItem(lambda item: f"Paired phones: {len(devices)}", None, enabled=False),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Start with Windows", toggle_autostart,
                         checked=lambda item: autostart_enabled()),
        pystray.MenuItem("Forget all phones", forget_phones),
        pystray.MenuItem("Quit", quit_app),
    )
    pystray.Icon("ShutdownScheduler", make_icon_image(), "Shutdown Scheduler", menu).run()


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))  # no data is sent; just picks the Wi-Fi/LAN address
        return s.getsockname()[0]
    except OSError:
        return "unknown"
    finally:
        s.close()


def already_running():
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\ShutdownSchedulerPC")
    return ctypes.windll.kernel32.GetLastError() == 183  # ERROR_ALREADY_EXISTS


def start_server():
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    app.run(host="0.0.0.0", port=HTTP_PORT, threaded=True, use_reloader=False)


if __name__ == "__main__":
    if not IS_WINDOWS:
        print(f"Shutdown Scheduler (no tray on this OS) as '{socket.gethostname()}' on port {HTTP_PORT}.")
        start_server()
        sys.exit(0)

    if already_running():
        info_box("Shutdown Scheduler is already running. Look for its icon in the system tray "
                 "(near the clock; you may need to click the ^ arrow).")
        sys.exit(0)

    first_run = not FIRST_RUN_FILE.exists()
    if first_run:
        set_autostart(True)
        APP_DIR.mkdir(parents=True, exist_ok=True)
        FIRST_RUN_FILE.write_text("1")
    elif autostart_enabled():
        set_autostart(True)  # refresh the path in case the .exe was moved

    threading.Thread(target=start_server, daemon=True).start()

    if first_run:
        info_box(
            "Shutdown Scheduler is running and will start automatically with Windows.\n\n"
            f"In the phone app, connect to this PC using either:\n"
            f"    Name:  {socket.gethostname()}\n"
            f"    IP:      {local_ip()}\n\n"
            "Its icon is in the system tray (near the clock). Right-click it to turn "
            "'Start with Windows' off or to quit.\n\n"
            "If Windows Firewall asks, allow access on PRIVATE networks so your phone "
            "can connect."
        )

    run_tray()
