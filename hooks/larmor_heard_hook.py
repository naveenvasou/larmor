#!/usr/bin/env python3
"""PostToolUse hook: hand the agent what the user said while it was working.

Without this, speech during work waits in the buffer until the agent next calls
listen(), which can be minutes into a long task. The user says "no, the other
file" and the agent keeps editing the wrong one. Claude Code runs this hook after
every tool call (so does Codex, with the same hook format), so turns reach the agent at the next tool boundary, usually
within seconds, as added context on that tool's result.

Delivered turns are marked in ~/.larmor/delivered_until so listen() never
returns them a second time. Only the session that owns voice mode gets them, and
Larmor's own tools are skipped: after speak/listen the agent is already in the
conversation.

Any exception => exit 0 with no output. Never blocks anything.
"""
import json
import os
import sys

HOME = os.path.expanduser("~/.larmor")
SESSION = os.path.join(HOME, "session")
TURNS = os.path.join(HOME, "turns.jsonl")
DELIVERED = os.path.join(HOME, "delivered_until")
TAIL_BYTES = 256 * 1024
_SAID = []


def _float(path: str) -> float:
    try:
        return float(open(path).read().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def main() -> int:
    payload = json.loads(sys.stdin.read() or "{}")
    if str(payload.get("tool_name", "")).startswith("mcp__larmor__"):
        return 0
    s = json.loads(open(SESSION).read())
    if not s.get("on") or not s.get("session_id") or payload.get("session_id") != s["session_id"]:
        return 0
    since = max(_float(DELIVERED), float(s.get("since", 0)))
    with open(TURNS, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL_BYTES))
        lines = f.read().decode(errors="replace").splitlines()
    said, newest = [], since
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        t, text = float(ev.get("wall_clock") or 0), (ev.get("text") or "").strip()
        if ev.get("type") != "turn" or not text or t <= since:
            continue
        said.append(("(you were cut off mid-sentence) " if ev.get("interrupted_agent") else "") + text)
        newest = max(newest, t)
    if not said:
        return 0
    tmp = DELIVERED + ".tmp"
    with open(tmp, "w") as f:
        f.write(repr(newest))
    os.replace(tmp, DELIVERED)
    quoted = "\n".join(f'  "{t}"' for t in said)
    _SAID.append(1)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            "[Larmor] While you were working, the user said (by voice):\n" + quoted + "\n"
            "This will NOT come through listen(). Act on it now: acknowledge it with speak(), "
            "and change course if it redirects your work."),
    }}))
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    except Exception:
        rc = 0
    if rc == 0 and not _SAID:
        print("{}")                   # Codex wants JSON on stdout even when there's nothing to add
    sys.exit(rc)
