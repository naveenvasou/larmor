#!/usr/bin/env bash
# Larmor — talk to your terminal coding agent. One command sets up everything:
#
#   ./install.sh                 # runtime + menu-bar app + every agent it finds
#   ./install.sh claude          # same, but only wire Claude Code (or gemini|antigravity|codex)
#   ./install.sh --no-agents     # runtime + menu-bar app, leave agent configs alone
#   ./install.sh --uninstall     # stop the app and remove the login item (agent configs stay)
#   ./install.sh --print         # show the MCP config, install nothing
#
# Everything runs on your Mac: Parakeet for speech-to-text, Chatterbox for the voice,
# Apple's echo canceller so you can talk over it. Apple Silicon only. The first launch
# downloads about 3.7 GB of models in the background; the menu-bar icon shows progress.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$DIR/.venv-app"
PY="$VENV/bin/python"
SERVER="$DIR/larmor_server.py"
SKILL="$DIR/skills/larmor/SKILL.md"
LABEL="dev.larmor.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

json_config() {
  cat <<EOF
{
  "mcpServers": {
    "larmor": {
      "command": "$PY",
      "args": ["$SERVER"]
    }
  }
}
EOF
}

# ── runtime ───────────────────────────────────────────────────────────────────

check_mac() {
  [ "$(uname -s)" = Darwin ] || die "Larmor runs on macOS only"
  [ "$(uname -m)" = arm64 ] || die "Larmor needs an Apple Silicon Mac (M1 or later)"
  local major; major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || die "Larmor needs macOS 14 or later"
}

install_runtime() {
  if ! command -v uv >/dev/null; then
    say "→ installing uv (Python package manager)"
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
    export PATH="$HOME/.local/bin:$PATH"
  fi
  say "→ Python environment (about 800 MB, a minute or two)"
  [ -x "$PY" ] || uv venv -q --python 3.12 "$VENV"
  VIRTUAL_ENV="$VENV" uv pip install -q -r "$DIR/requirements.txt"
  chmod +x "$DIR/native/larmor_audio"
  xattr -d com.apple.quarantine "$DIR/native/larmor_audio" 2>/dev/null || true
  mkdir -p "$HOME/.larmor"
}

install_app() {
  say "→ menu-bar app (starts at login)"
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>$DIR/app/larmor_menubar.py</string></array>
  <key>RunAtLoad</key><true/>
  <!-- restart after a crash, but not after "Quit Larmor" from the menu -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/.larmor/menubar.log</string>
  <key>StandardErrorPath</key><string>$HOME/.larmor/menubar.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
}

uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  say "Larmor app stopped and removed from login items."
  say "Agent configs, the Python environment and downloaded models are untouched."
  say "To remove the MCP server from Claude Code: claude mcp remove larmor -s user"
}

# ── agents ────────────────────────────────────────────────────────────────────

install_claude() {
  command -v claude >/dev/null || { say "  claude: not found, skipping"; return; }
  claude mcp remove larmor -s user >/dev/null 2>&1 || true
  claude mcp add larmor -s user -- "$PY" "$SERVER" >/dev/null
  say "  claude: MCP server registered"
  mkdir -p ~/.claude/skills/larmor
  cp "$SKILL" ~/.claude/skills/larmor/SKILL.md
  say "  claude: /larmor skill installed"
  # The Stop hook keeps a turn from ending while voice mode is on (Claude-specific)
  "$PY" - "$PY" "$DIR" <<'PYEOF'
import json, os, sys
py, d = sys.argv[1], sys.argv[2]
p = os.path.expanduser("~/.claude/settings.json")
try: c = json.load(open(p))
except Exception: c = {}
st = c.setdefault("hooks", {}).setdefault("Stop", [])
cmd = f"{py} {d}/hooks/larmor_stop_hook.py"
if any("larmor_stop_hook" in json.dumps(m) for m in st):
    print("  claude: Stop hook already registered")
else:
    st.append({"hooks": [{"type": "command", "command": cmd}]})
    json.dump(c, open(p, "w"), indent=2)
    print("  claude: Stop hook registered")
# start_voice -> record which session turned voice on, so only that one is held to it
ptu = c["hooks"].setdefault("PostToolUse", [])
if not any("larmor_claim_hook" in json.dumps(m) for m in ptu):
    ptu.append({"matcher": "mcp__larmor__start_voice",
                "hooks": [{"type": "command", "command": f"{py} {d}/hooks/larmor_claim_hook.py"}]})
    json.dump(c, open(p, "w"), indent=2)
    print("  claude: session-scoping hook registered")
# after every tool call: hand the agent anything the user said while it worked
if not any("larmor_heard_hook" in json.dumps(m) for m in ptu):
    ptu.append({"hooks": [{"type": "command", "command": f"{py} {d}/hooks/larmor_heard_hook.py",
                           "timeout": 5}]})
    json.dump(c, open(p, "w"), indent=2)
    print("  claude: mid-work speech hook registered")
PYEOF
}

_json_mcp() {  # file  label
  "$PY" - "$1" "$PY" "$SERVER" <<'PYEOF'
import json, os, sys
p, py, server = sys.argv[1:]
p = os.path.expanduser(p)
try: c = json.load(open(p))
except Exception: c = {}
c.setdefault("mcpServers", {})["larmor"] = {"command": py, "args": [server]}
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(c, open(p, "w"), indent=2)
PYEOF
}

install_gemini() {
  command -v gemini >/dev/null || { say "  gemini: not found, skipping"; return; }
  _json_mcp ~/.gemini/settings.json
  say "  gemini: MCP server added; paste skills/larmor/SKILL.md into GEMINI.md for the speaking rules"
}

install_antigravity() {
  command -v agy >/dev/null || [ -d ~/.gemini/config ] || { say "  antigravity: not found, skipping"; return; }
  _json_mcp ~/.gemini/config/mcp_config.json
  mkdir -p ~/.gemini/skills/larmor
  cp "$SKILL" ~/.gemini/skills/larmor/SKILL.md
  say "  antigravity: MCP server + skill installed"
}

install_codex() {
  command -v codex >/dev/null || { say "  codex: not found, skipping"; return; }
  local f=~/.codex/config.toml
  mkdir -p ~/.codex
  if grep -q "mcp_servers.larmor" "$f" 2>/dev/null; then
    say "  codex: already configured"
  else
    cat >> "$f" <<EOF

[mcp_servers.larmor]
command = "$PY"
args = ["$SERVER"]
EOF
    say "  codex: MCP server added; paste skills/larmor/SKILL.md into AGENTS.md for the speaking rules"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

target="${1:-all}"
case "$target" in
  --print)     json_config; exit 0 ;;
  --uninstall) uninstall; exit 0 ;;
  all|claude|gemini|antigravity|codex|--no-agents) ;;
  *) die "usage: $0 [claude|gemini|antigravity|codex|--no-agents|--uninstall|--print]" ;;
esac

check_mac
install_runtime
install_app

if [ "$target" != --no-agents ]; then
  say "→ wiring your coding agents"
  case "$target" in
    all) install_claude; install_gemini; install_antigravity; install_codex ;;
    *)   "install_$target" ;;
  esac
fi

cat <<EOF

Done. A waveform icon is now in your menu bar.
  • First launch downloads the models (about 3.7 GB). The icon shows the percentage;
    when it turns into a plain waveform, you're ready.
  • Restart your agent, then type /larmor (Claude Code) or ask it for "voice mode".
  • The first time, macOS asks your terminal for microphone access. Allow it.
  • Use headphones or speakers, either works: you can talk over it and it stops.
  • Can't see the icon? A full menu bar hides it. Hold ⌘ and drag other icons out.
EOF
