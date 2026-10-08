#!/usr/bin/env python3
"""Stop hook: a turn must never end while voice mode is on.

If voice mode is on, ending the turn leaves the user talking to a process that
isn't listening, and they get no error. The only ways out are listen() (the
conversation continues) or end_voice() (it's over). The state is binary, so the
hook is too: no grace periods or block caps, which only ever went quiet exactly
when they were needed.

Scoped to one session: the claim hook records which session called start_voice,
and only that session is held to it. Other sessions on the same machine are left
alone.

SAFETY: `stop_hook_active` is honoured (the harness sets it on a stop this hook
already forced, so it cannot loop), and any exception exits 0. Escape hatch:
end_voice(), or `rm ~/.larmor/session`.
"""
import json
import os
import sys

SESSION = os.path.expanduser("~/.larmor/session")


def main() -> int:
    payload = json.loads(sys.stdin.read() or "{}")
    if payload.get("stop_hook_active"):
        return 0                       # never re-block a stop this hook already forced
    try:
        session = json.loads(open(SESSION).read())
    except (OSError, ValueError):
        return 0                       # no session file => not in voice mode
    if not session.get("on"):
        return 0
    owner = session.get("session_id")
    if not owner or payload.get("session_id") != owner:
        return 0                       # voice mode belongs to another session (or is unclaimed)
    print("Voice mode is ON and you are ending your turn. The user is waiting "
          "and cannot reach you. Call the larmor listen tool now. If the "
          "conversation is genuinely over, call end_voice first.",
          file=sys.stderr)
    return 2                           # exit 2 = block; stderr goes to the agent


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)                    # fail open, always
