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
# The only thing Larmor ever sends anywhere, and only if the user types it: an email
# for updates, and feedback from the menu bar. No usage data, no audio, no transcripts.
SIGNUP_URL="${LARMOR_SIGNUP_URL:-https://2htivf76db7g5cbqk2zaq4r25a0vcnxj.lambda-url.ap-south-1.on.aws/}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

LOG="$HOME/.larmor/install.log"

# ── look ──────────────────────────────────────────────────────────────────────
# Colors and spinners only on a real terminal; plain lines when an agent or a pipe runs us.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  FANCY=1
  B=$'\033[1m' D=$'\033[2m' G=$'\033[38;5;79m' E=$'\033[38;5;209m' R=$'\033[38;5;203m' X=$'\033[0m'
else
  FANCY=0 B="" D="" G="" E="" R="" X=""
fi
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

say() { printf '%s\n' "$*"; }
die() { printf '\n  %s✗%s %s\n\n' "$R" "$X" "$*" >&2; exit 1; }
ok()  { printf '  %s✓%s %s %s%s%s\n' "$G" "$X" "$1" "$D" "${2:-}" "$X"; }

banner() {
  printf '\n'
  printf '  %s╻  ┏━┓┏━┓┏┳┓┏━┓┏━┓%s\n' "$G" "$X"
  printf '  %s┃  ┣━┫┣┳┛┃┃┃┃ ┃┣┳┛%s   %sTalk to your coding agent.%s\n' "$G" "$X" "$B" "$X"
  printf '  %s┗━╸╹ ╹╹┗╸╹ ╹┗━┛╹┗╸%s   %sRuns on your Mac · free in beta%s\n\n' "$G" "$X" "$D" "$X"
}

took() {  # seconds since $1, as "12s" or "1m 05s"
  local s=$(( $(date +%s) - $1 ))
  if [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s / 60)) $((s % 60)); elif [ "$s" -ge 1 ]; then printf '%ds' "$s"; fi
}

# step "label" fn [args]: run fn quietly (its output goes to the log) behind a spinner,
# then ✓ or ✗. STEP_SHOW=1 prints the step's own output underneath, dimmed.
step() {
  local label="$1"; shift
  local t0 out pid st=0 i=0
  t0=$(date +%s); out="$(mktemp)"
  if [ "$FANCY" = 1 ]; then
    ( "$@" ) >"$out" 2>&1 &
    pid=$!
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s%s%s\033[K' "$G" "${SPIN[$i]}" "$X" "$label" "$D" "$(took "$t0")" "$X"
      i=$(( (i + 1) % ${#SPIN[@]} )); sleep 0.08
    done
    wait "$pid" || st=$?
    printf '\r\033[K\033[?25h'
  else
    say "  → $label"
    ( "$@" ) >"$out" 2>&1 || st=$?
  fi
  cat "$out" >> "$LOG"
  if [ "$st" -ne 0 ]; then
    printf '  %s✗%s %s\n' "$R" "$X" "$label"
    tail -n 12 "$out" | sed 's/^/    /' >&2; rm -f "$out"
    die "Install stopped. The full log is in ~/.larmor/install.log"
  fi
  [ "$FANCY" = 1 ] && ok "$label" "$(took "$t0")"
  if [ "${STEP_SHOW:-0}" = 1 ]; then
    grep -v "not found, skipping" "$out" | sed -e 's/^ *//' -e "s/^/    ${D}· /" -e "s/\$/${X}/" || true
  fi
  rm -f "$out"
}

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

install_uv() {
  curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_runtime() {
  [ -x "$PY" ] || uv venv -q --python 3.12 "$VENV"
  VIRTUAL_ENV="$VENV" uv pip install -q -r "$DIR/requirements.txt"
  chmod +x "$DIR/native/larmor_audio"
  xattr -d com.apple.quarantine "$DIR/native/larmor_audio" 2>/dev/null || true
}

install_app() {
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

# ── email ─────────────────────────────────────────────────────────────────────
# Required: it's how a beta user hears about updates and the end of the beta. Asked
# first, so nobody sits through the install and then gets stopped. curl | bash hands us
# the script on stdin, so the question goes to the terminal itself.

EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$'

send_email() {  # curl, not python: a fresh Mac without developer tools has no real python3
  curl -fsS -m 8 -H 'content-type: application/json' \
    -d "{\"kind\":\"email\",\"email\":\"$1\",\"version\":\"beta\"}" "$SIGNUP_URL"
}

valid_email() {
  case "$1" in *\"*|*\\*) return 1 ;; esac
  [[ $1 =~ $EMAIL_RE ]]
}

get_email() {
  local email="${LARMOR_EMAIL:-}" tries=0
  if [ -z "$email" ] && [ -s "$HOME/.larmor/email" ]; then
    ok "Signed up as $(head -n 1 "$HOME/.larmor/email")"
    return
  fi
  if [ -z "$email" ]; then
    if ! (: </dev/tty) 2>/dev/null; then
      die "Larmor needs an email to install, and there's no terminal to ask in. Run it like this:
      curl -fsSL https://larmor.dev/install.sh | LARMOR_EMAIL=you@example.com bash"
    fi
    printf '  Larmor is free while it'\''s in beta. Your email is how you hear about\n' >/dev/tty
    printf '  updates and when the beta ends. It'\''s the only thing Larmor collects.\n\n' >/dev/tty
    while :; do
      printf '  %s›%s Email: ' "$E" "$X" >/dev/tty
      IFS= read -r email </dev/tty || die "Cancelled."
      email="$(printf '%s' "$email" | tr -d '[:space:]')"
      valid_email "$email" && break
      tries=$((tries + 1))
      [ "$tries" -ge 3 ] && die "That doesn't look like an email. Run the command again when you're ready."
      printf '    %sThat doesn'\''t look like an email. Try again.%s\n' "$D" "$X" >/dev/tty
    done
    printf '\n' >/dev/tty
  elif ! valid_email "$email"; then
    die "LARMOR_EMAIL doesn't look like an email: $email"
  fi
  printf '%s\n' "$email" > "$HOME/.larmor/email"
  if send_email "$email" >>"$LOG" 2>&1; then
    rm -f "$HOME/.larmor/email_unsent"
    ok "Signed up as $email"
  else
    touch "$HOME/.larmor/email_unsent"
    ok "Saved $email" "(couldn't reach the server, carrying on)"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

wire_agents() {
  case "$target" in
    all) install_claude; install_gemini; install_antigravity; install_codex ;;
    *)   "install_$target" ;;
  esac
}

finish() {
  printf '\n  %sLarmor is installed.%s\n\n' "$B" "$X"
  printf '  %s1%s  The menu-bar icon is fetching the voice models (about 3.7 GB, first time\n' "$E" "$X"
  printf '     only). When it turns into a plain waveform, you'\''re ready.\n'
  printf '  %s2%s  Restart Claude Code and type %s/larmor%s. Other agents: ask for "voice mode".\n' "$E" "$X" "$B" "$X"
  printf '  %s3%s  When macOS asks for microphone access for your terminal, allow it.\n\n' "$E" "$X"
  printf '  %sHeadphones or speakers both work, and you can talk over it.%s\n' "$D" "$X"
  printf '  %sNo icon? A full menu bar hides it: hold ⌘ and drag other icons away.%s\n' "$D" "$X"
  printf '  %sSomething off? Menu-bar icon → Send feedback.%s\n\n' "$D" "$X"
}

main() {
  target="${1:-all}"
  case "$target" in
    --print)     json_config; exit 0 ;;
    --uninstall) uninstall; exit 0 ;;
    all|claude|gemini|antigravity|codex|--no-agents) ;;
    *) die "usage: $0 [claude|gemini|antigravity|codex|--no-agents|--uninstall|--print]" ;;
  esac
  trap '[ "$FANCY" = 1 ] && printf "\033[?25h"' EXIT
  mkdir -p "$HOME/.larmor"; : > "$LOG"
  banner
  check_mac
  get_email
  if [ -n "${LARMOR_FETCHED:-}" ]; then ok "Downloaded Larmor" "$LARMOR_FETCHED"; fi
  if ! command -v uv >/dev/null; then
    step "Installing uv, the Python package manager" install_uv
    export PATH="$HOME/.local/bin:$PATH"
  fi
  step "Setting up Python and the speech libraries (about 800 MB)" install_runtime
  step "Adding the menu-bar app (starts at login)" install_app
  if [ "$target" != --no-agents ]; then
    STEP_SHOW=1 step "Connecting your coding agents" wire_agents
  fi
  finish
}

[ -n "${LARMOR_NO_MAIN:-}" ] || main "$@"
