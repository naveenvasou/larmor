"""Larmor menu-bar app: keeps the local engine running and shows its state.

One icon in the menu bar. It starts the engine (speech-to-text + voice) at login,
restarts it if it dies, and shows the first-run model download as a percentage.
No settings yet, on purpose: the first test is whether people use voice mode at all.

    python app/larmor_menubar.py
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import rumps

HERE = Path(__file__).resolve().parent.parent
PORT = int(os.getenv("LARMOR_ENGINE_PORT", "8160"))
HEALTH = f"http://127.0.0.1:{PORT}/health"
HOME = Path.home() / ".larmor"
ENGINE_LOG = HOME / "engine.log"

# SF Symbols, drawn as template images so they follow light/dark menu bars.
# Not a record dot: a mic app showing one reads as "always recording".
SYMBOL = {"ready": "waveform", "downloading": "arrow.down.circle", "loading": "ellipsis.circle",
          "starting": "ellipsis.circle", "stopped": "waveform.slash", "error": "exclamationmark.triangle"}


def fetch_health():
    try:
        with urllib.request.urlopen(HEALTH, timeout=1) as r:
            return json.load(r)
    except Exception:
        return None


def describe(h, running: bool) -> str:
    if h is None:
        return "Starting engine…" if running else "Engine stopped"
    st = h.get("state")
    if st == "downloading":
        total = h.get("total_mb") or 0
        have = h.get("downloaded_mb") or 0
        if total:
            return f"Downloading models… {int(h.get('progress', 0) * 100)}% ({have / 1000:.1f} of {total / 1000:.1f} GB)"
        return f"Downloading models… {have / 1000:.1f} GB"
    if st == "loading":
        return "Loading models…"
    if st == "ready":
        return "Ready — type /larmor in your agent"
    if st == "error":
        return f"Error: {h.get('detail', '')[:60]}"
    return "Starting engine…"


class Engine:
    """Owns the engine child process. If something already serves the port (a dev
    copy, a second menu-bar instance), we watch it instead of starting another."""

    def __init__(self):
        self.proc = None
        self.wanted = True
        self.fails = 0
        self.next_try = 0.0

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        self.wanted = True
        if self.running or fetch_health() is not None:
            return
        HOME.mkdir(exist_ok=True)
        log = open(ENGINE_LOG, "ab")
        self.proc = subprocess.Popen(
            [sys.executable, str(HERE / "engine" / "larmor_engine.py")],
            stdout=log, stderr=subprocess.STDOUT, cwd=str(HERE),
            env=dict(os.environ, LARMOR_ENGINE_PORT=str(PORT), PYTHONUNBUFFERED="1",
                     LARMOR_ENGINE_PARENT=str(os.getpid())))

    def stop(self):
        self.wanted = False
        if self.running:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def tick(self):
        """Restart a crashed engine, backing off so a broken install doesn't spin."""
        if not self.wanted or self.running:
            if self.running:
                self.fails = 0
            return
        if self.proc is not None:                      # it was ours and it died
            self.fails += 1
            self.proc = None
            self.next_try = time.time() + min(60, 2 ** self.fails)
        if time.time() >= self.next_try:
            self.start()


class App(rumps.App):
    def __init__(self):
        super().__init__("Larmor", title="Larmor", quit_button=None)
        self.symbol = None
        self.engine = Engine()
        self.status = rumps.MenuItem("Starting engine…")
        self.toggle = rumps.MenuItem("Stop engine", callback=self.on_toggle)
        self.menu = [self.status, None, self.toggle,
                     rumps.MenuItem("Open engine log", callback=self.on_log),
                     None, rumps.MenuItem("Quit Larmor", callback=self.on_quit)]
        self.was_ready = None
        self.engine.start()
        rumps.Timer(self.refresh, 1).start()

    def refresh(self, _=None):
        self.engine.tick()
        h = fetch_health()
        st = (h or {}).get("state") or ("starting" if self.engine.wanted else "stopped")
        self.set_symbol(SYMBOL.get(st, SYMBOL["starting"]))
        self.title = f" {int(h['progress'] * 100)}%" if st == "downloading" and h.get("total_mb") else ""
        self.status.title = describe(h, self.engine.wanted)
        self.toggle.title = "Stop engine" if self.engine.wanted else "Start engine"
        ready = st == "ready"
        if ready and self.was_ready is False:          # only after we watched it get ready
            rumps.notification("Larmor", "Ready", "Voice mode is ready. Type /larmor in your agent.")
        self.was_ready = ready

    def set_symbol(self, name: str):
        if name == self.symbol:
            return
        try:
            from AppKit import NSImage
            img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, "Larmor")
            img.setTemplate_(True)
            self._nsapp.nsstatusitem.button().setImage_(img)
            self.symbol = name
        except Exception:                              # older macOS: fall back to text
            self.title = "Larmor"

    def on_toggle(self, _):
        if self.engine.wanted:
            self.engine.stop()
        else:
            self.engine.start()
        self.refresh()

    def on_log(self, _):
        ENGINE_LOG.touch()
        subprocess.Popen(["open", "-a", "Console", str(ENGINE_LOG)])

    def on_quit(self, _):
        self.engine.stop()
        rumps.quit_application()


if __name__ == "__main__":
    try:                                               # menu-bar only, no Dock icon
        from AppKit import NSApplication
        NSApplication.sharedApplication().setActivationPolicy_(1)
    except Exception:
        pass
    App().run()
