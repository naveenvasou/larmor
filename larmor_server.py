#!/usr/bin/env python3
"""Larmor — an MCP server that gives a coding agent ears and a voice.

This process is plumbing: no LLM, it never answers for the agent.
  - speak(text)  hands a line to the ear, which plays it through Apple's echo
                 canceller; returns in ~10 ms while the audio plays.
  - listen()     blocks until the user finishes a spoken turn and returns the
                 transcript. Turns spoken while the agent was busy are buffered,
                 so listen() returns at once with them: speech is never lost.

The ear (larmor_ear.py) owns the microphone while voice mode is on. It writes
finished turns to ~/.larmor/turns.jsonl, which this server tails.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import requests
from mcp.server import MCPServer

HOME = Path(os.path.expanduser("~/.larmor"))
HOME.mkdir(exist_ok=True)
TURNS = HOME / "turns.jsonl"
TURNS.touch()
SESSION = HOME / "session"          # voice mode on/off + who owns the mic; read by the hooks
METRICS = HOME / "metrics.jsonl"
EAR_INFO = HOME / "ear.json"
# Newest turn already handed to the agent, by listen() or by the heard hook (which
# delivers speech mid-work at tool boundaries). Shared so nothing arrives twice.
DELIVERED = HOME / "delivered_until"
EAR_LOG = HOME / "ear.log"
EAR_SCRIPT = str(Path(__file__).resolve().parent / "larmor_ear.py")
ENGINE = os.getenv("LARMOR_ENGINE_URL", "http://127.0.0.1:8160")

POLL_S = 0.02                       # 20 ms: the transport should never be the bottleneck
# A mic claim is a lease, not a lock: sessions get abandoned (escape, closed terminal)
# without end_voice(), and a lock would then block every other agent forever. The
# owner renews it on every listen(); a stale lease is free for the taking.
LEASE_S = float(os.getenv("LARMOR_LEASE_S", "90"))
# Voice mode also has to let go of the mic on its own. While it's on, the ear keeps the
# mic open through Apple's echo canceller, which turns down every other app's audio
# whenever it hears speech. Two ways a session gets abandoned with voice still on:
#   - the agent stops calling the tools at all (a Claude Desktop chat that was left;
#     no Stop hook there to keep it listening): no speak()/listen() for IDLE_OFF_S;
#   - the agent keeps calling listen() but nobody has spoken for SILENCE_OFF_S.
IDLE_OFF_S = float(os.getenv("LARMOR_IDLE_OFF_S", "600"))
SILENCE_OFF_S = float(os.getenv("LARMOR_SILENCE_OFF_S", "1200"))
AUTO_OFF_NOTE = ("voice mode switched itself off: {why}, so Larmor let go of the microphone. "
                 "Don't call listen() again. If the user wants to talk, call start_voice().")

# Sent to every MCP client at connect, so any agent gets the speaking rules even where
# the larmor skill isn't installed. The skill (skills/larmor/SKILL.md) is the long form.
INSTRUCTIONS = """\
Larmor lets the user talk with you by voice. None of this applies until they ask for voice
mode (or type /larmor or $larmor). Then:

- Call start_voice() once. Loop: speak(reply) -> listen() -> work -> speak(reply) -> listen().
  Never end your turn without calling listen(). Call end_voice() only when they say they're done.
  On "(silence)", just listen() again.
- Speak 1-3 short sentences per speak() call. Lead with the answer. Never speak markdown, code,
  file paths or URLs; put detail on the terminal and say one line about it. Round numbers.
- Before your first tool call on any real work, speak a short receipt ("one sec, checking the
  config"). During long work, speak a short progress beat at each milestone.
- What the user says while you work comes back in the result of your next speak() call (and,
  in agents with Larmor's hooks, after your next tool call). Treat it as their turn: acknowledge
  it and change course if it redirects you. It will not come through listen() again.
- If listen() says you were cut off, open with a couple of words owning it, then answer.
- Don't write on-screen summaries of what you just said aloud. Your reply is the speak() call.
"""

mcp = MCPServer("larmor", instructions=INSTRUCTIONS)
OWNER = os.getpid()                 # each agent spawns its own server, so the pid identifies it
_state = {"cursor": None, "buffered": [], "was_away": False}
_ear = {"proc": None}
_calls = {"in_flight": 0, "last": 0.0, "heard": 0.0, "off_why": None, "watch": None}
_calls_lock = threading.Lock()


class _call:
    """Counts a voice tool call as activity for the idle watch, for its whole duration."""
    def __enter__(self):
        with _calls_lock:
            _calls["in_flight"] += 1
            _calls["last"] = time.time()

    def __exit__(self, *exc):
        with _calls_lock:
            _calls["in_flight"] -= 1
            _calls["last"] = time.time()


def _metric(kind: str, **fields) -> None:
    fields.update({"kind": kind, "wall": time.time()})
    with open(METRICS, "a") as f:
        f.write(json.dumps(fields) + "\n")


def _read_session() -> dict:
    try:
        return json.loads(SESSION.read_text())
    except (OSError, ValueError):
        return {}


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def _owns_mic() -> bool:
    """True if nobody holds the mic, we do, or the holder is gone or idle past the lease."""
    s = _read_session()
    owner = s.get("owner")
    if owner is None or owner == OWNER or not _pid_alive(owner):
        return True
    return (time.time() - float(s.get("last_listen", 0) or 0)) > LEASE_S


def _touch(field: str) -> None:
    s = _read_session()
    if not s.get("on"):
        return
    s[field] = time.time()
    try:
        SESSION.write_text(json.dumps(s))
    except OSError:
        pass


# ── turns ─────────────────────────────────────────────────────────────────────

def _delivered() -> float:
    try:
        return float(DELIVERED.read_text().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def _mark_delivered(t: float) -> None:
    if t > _delivered():
        tmp = HOME / "delivered_until.tmp"
        tmp.write_text(repr(t))
        tmp.replace(DELIVERED)


def _skip_turns() -> None:
    """Fast-forward past anything unread: those words were said to another agent."""
    if _state["cursor"] is None:
        _state["cursor"] = open(TURNS)
    _state["cursor"].seek(0, os.SEEK_END)


def _drain() -> list[dict]:
    if _state["cursor"] is None:
        _skip_turns()
    out = []
    done = _delivered()
    while line := _state["cursor"].readline():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = (ev.get("text") or "").strip()
        if ev.get("type") != "turn" or not text or float(ev.get("wall_clock") or 0) <= done:
            continue
        if ev.get("interrupted_agent"):
            text = "(you were cut off mid-sentence) " + text
        out.append({"text": text, "t_user_end": ev.get("wall_clock", time.time()),
                    "t_seen": time.time()})
    return out


@mcp.tool()
def listen(timeout_s: float = 300.0) -> str:
    """Block until the user finishes a spoken turn; return the transcript.

    Returns instantly if the user spoke while you were working (turns are
    buffered — speech is never lost). Multiple buffered turns are joined in
    order. Returns "(silence)" on timeout. Call speak() first if you owe the
    user a reply; call listen() again right after to keep the conversation.
    """
    if _calls["off_why"] and not _ear_alive():
        return AUTO_OFF_NOTE.format(why=_calls["off_why"])
    with _call():
        return _listen(timeout_s)


def _listen(timeout_s: float) -> str:
    t_call = time.time()
    if not _owns_mic():
        _state["buffered"].clear()
        _skip_turns()
        _state["was_away"] = True
        return ("(another agent holds voice mode — this session is not listening. "
                "Call start_voice() to take over, or stay quiet.)")
    if _state["was_away"]:                       # regained the mic: don't replay their talk
        _state["was_away"] = False
        _state["buffered"].clear()
        _skip_turns()
    _touch("last_listen")
    deadline = t_call + timeout_s
    turns: list[dict] = []
    while True:
        _state["buffered"].extend(_drain())
        # the heard hook may have delivered some of these mid-work after we buffered them
        done = _delivered()
        turns = [t for t in _state["buffered"] if t["t_user_end"] > done]
        _state["buffered"] = []
        if turns or time.time() >= deadline:
            break
        time.sleep(POLL_S)
    if not turns:
        # the heard hook delivers mid-work speech too; delivered_until covers both paths
        if _ear_alive() and time.time() - max(_calls["heard"], _delivered()) > SILENCE_OFF_S:
            _auto_off(f"nobody has spoken for {int(SILENCE_OFF_S // 60)} minutes")
            return AUTO_OFF_NOTE.format(why=_calls["off_why"])
        return "(silence)"
    _calls["heard"] = time.time()
    _mark_delivered(max(t["t_user_end"] for t in turns))
    t_ret = time.time()
    for t in turns:
        _metric("listen_turn", total_ms=round((t_ret - t["t_user_end"]) * 1000, 1),
                buffered=t["t_seen"] < t_call)
    return "\n".join(t["text"] for t in turns)


# ── voice ─────────────────────────────────────────────────────────────────────

def _ear_alive() -> bool:
    p = _ear["proc"]
    return p is not None and p.poll() is None


def _ear_port() -> int:
    for _ in range(100):                         # the ear writes its port once audio is up
        try:
            return int(json.loads(EAR_INFO.read_text())["port"])
        except (OSError, ValueError, KeyError):
            time.sleep(0.1)
    raise RuntimeError("ear control port not available")


def _start_ear() -> None:
    if _ear_alive():
        return
    env = dict(os.environ, LARMOR_PARENT_PID=str(OWNER), LARMOR_ENGINE_URL=ENGINE)
    _ear["proc"] = subprocess.Popen([sys.executable, EAR_SCRIPT], env=env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=open(EAR_LOG, "a"))


def _stop_ear() -> None:
    p = _ear["proc"]
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
    _ear["proc"] = None


def _auto_off(why: str) -> None:
    """end_voice() on the agent's behalf; only flips the session if it's still ours."""
    if _read_session().get("owner") == OWNER:
        SESSION.write_text(json.dumps({"on": False, "since": time.time()}))
    _stop_ear()
    _calls["off_why"] = why
    _metric("voice_auto_off", why=why)


def _idle_watch() -> None:
    while _ear_alive():
        time.sleep(min(5.0, IDLE_OFF_S / 4))
        with _calls_lock:
            idle = _calls["in_flight"] == 0 and time.time() - _calls["last"] > IDLE_OFF_S
        if idle and _ear_alive():
            _auto_off(f"there was no speak() or listen() call for {int(IDLE_OFF_S // 60)} minutes")
            return


@mcp.tool()
def speak(text: str) -> str:
    """Say a line to the user. Returns immediately (~10ms) while audio plays.

    Keep it to 1-3 spoken sentences — detail belongs on the terminal, not in
    the voice. Never speak markdown, code, or file paths.
    """
    if not _ear_alive():
        if _calls["off_why"]:
            return AUTO_OFF_NOTE.format(why=_calls["off_why"])
        return "voice mode is off: call start_voice() first"
    with _call():
        return _speak(text)


def _speak(text: str) -> str:
    try:
        r = requests.post(f"http://127.0.0.1:{_ear_port()}/say", json={"text": text}, timeout=5)
    except Exception as e:  # noqa: BLE001
        return f"speak failed: {e}"
    _touch("last_speak")
    return f"queued ({r.json().get('queued', '?')} ahead)" + _heard_while_working()


def _heard_while_working() -> str:
    """Anything the user finished saying since the agent last heard them.

    This is how speech reaches the agent mid-work in every MCP client: agents narrate
    long work with speak(), so a turn arrives within one progress beat. Claude Code and
    Codex also get it sooner through the heard hook; both mark delivered_until, so a
    turn only ever arrives once.
    """
    if _state["was_away"] or not _owns_mic():
        return ""                                # listen() resyncs when we regain the mic
    _state["buffered"].extend(_drain())
    done = _delivered()
    turns = [t for t in _state["buffered"] if t["t_user_end"] > done]
    _state["buffered"] = []
    if not turns:
        return ""
    _calls["heard"] = time.time()
    _mark_delivered(max(t["t_user_end"] for t in turns))
    _metric("heard_on_speak", n=len(turns))
    quoted = "\n".join(f'  "{t["text"]}"' for t in turns)
    return ("\n\n[Larmor] While you were working, the user said (by voice):\n" + quoted + "\n"
            "This will NOT come through listen(). Act on it now: acknowledge it with speak(), "
            "and change course if it redirects your work.")


@mcp.prompt()
def larmor() -> str:
    """Start voice mode: talk with your coding agent through Larmor."""
    return ("Start Larmor voice mode now: call the larmor start_voice tool, greet me in one short "
            "spoken line with speak(), then listen(). Follow the Larmor speaking rules until I end it.")


@mcp.tool()
def start_voice() -> str:
    """Enter voice mode. Call this ONCE when the user asks to talk.

    While voice mode is active a Stop hook will refuse to let you end a turn
    without calling listen(), so the conversation cannot silently die.
    """
    now = time.time()
    if not _owns_mic():
        s = _read_session()
        idle = int(now - float(s.get("last_listen", now) or now))
        return (f"another agent is actively in voice mode (last heard {idle}s ago). "
                f"End voice mode there first, or if that session is gone, wait "
                f"{int(LEASE_S)}s and try again.")
    try:
        if requests.get(f"{ENGINE}/health", timeout=2).json().get("state") != "ready":
            return "the Larmor engine isn't ready yet (models may still be downloading; see the menu-bar icon)"
    except Exception:  # noqa: BLE001
        return "the Larmor engine isn't running: start the Larmor menu-bar app"
    # seed both stamps: a fresh session hasn't failed to listen yet
    SESSION.write_text(json.dumps({"on": True, "since": now, "owner": OWNER,
                                   "last_listen": now, "last_speak": now}))
    _state["buffered"].clear()
    _skip_turns()
    _state["was_away"] = False
    _start_ear()
    with _calls_lock:
        _calls.update(last=now, heard=now, off_why=None)
    if _calls["watch"] is None or not _calls["watch"].is_alive():
        _calls["watch"] = threading.Thread(target=_idle_watch, daemon=True)
        _calls["watch"].start()
    _metric("voice_start")
    return "voice mode ON — end every turn with listen(); call end_voice() to exit"


@mcp.tool()
def end_voice() -> str:
    """Leave voice mode. Call when the user says stop / that's all / exit voice."""
    SESSION.write_text(json.dumps({"on": False, "since": time.time()}))
    _stop_ear()
    _calls["off_why"] = None
    _metric("voice_end")
    return "voice mode OFF"


@mcp.tool()
def voice_status() -> str:
    """Health check: engine state, whether voice mode is on, recent listen latency."""
    out = {"voice_mode_on": bool(_read_session().get("on")), "ear_running": _ear_alive()}
    try:
        h = requests.get(f"{ENGINE}/health", timeout=2).json()
        out["engine"] = {k: h.get(k) for k in ("state", "progress", "detail")}
    except Exception as e:  # noqa: BLE001
        out["engine"] = f"DOWN: {e}"
    try:
        lines = METRICS.read_text().strip().splitlines()
        tot = [json.loads(l)["total_ms"] for l in lines if '"listen_turn"' in l][-20:]
        if tot:
            out["listen_latency_ms"] = {"n": len(tot), "p50": sorted(tot)[len(tot) // 2]}
    except (OSError, ValueError, KeyError):
        pass
    return json.dumps(out, indent=2)


if __name__ == "__main__":
    mcp.run()
