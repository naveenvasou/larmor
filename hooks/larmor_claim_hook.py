#!/usr/bin/env python3
"""PostToolUse hook on start_voice: tag voice mode with the session that turned it on.

Voice mode lives in one machine-wide file (~/.larmor/session). Hooks are told their
session_id but the MCP server is not, so the claim happens here: right after
start_voice succeeds, write this session's id into the file. The Stop hook then
holds only that session to listening, and every other session behaves normally.

Any exception => exit 0. Never blocks anything.
"""
import json
import os
import sys

SESSION = os.path.expanduser("~/.larmor/session")
_SAID = []


def main() -> int:
    payload = json.loads(sys.stdin.read() or "{}")
    if not str(payload.get("tool_name", "")).endswith("start_voice"):
        return 0
    sid = payload.get("session_id")
    if not sid or "voice mode ON" not in json.dumps(payload.get("tool_response", "")):
        return 0                      # refused (another agent holds the mic): claim nothing
    s = json.loads(open(SESSION).read())
    if s.get("on"):
        s["session_id"] = sid
        tmp = SESSION + ".tmp"
        with open(tmp, "w") as f:
            json.dump(s, f)
        os.replace(tmp, SESSION)
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    except Exception:
        rc = 0
    if rc == 0 and not _SAID:
        print("{}")                   # Codex wants JSON on stdout even when there's nothing to add
    sys.exit(rc)
