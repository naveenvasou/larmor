#!/usr/bin/env bash
# Larmor — talk to your terminal coding agent. One command sets up everything:
#
#   ./install.sh                 # runtime + menu-bar app + the agents you pick from those it finds
#   LARMOR_AGENTS=claude,codex   # pick without being asked
#   ./install.sh claude          # same, but only wire Claude Code (or desktop|codex|gemini|antigravity)
#   ./install.sh --no-agents     # runtime + menu-bar app, leave agent configs alone
#   ./install.sh --uninstall     # stop the app and remove the login item (agent configs stay)
#   ./install.sh --print         # the MCP config, for any other agent; installs nothing
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

# What Larmor needs, checked up front so nobody finds out halfway through.
# Measured: the engine holds about 2-3 GB of memory with both models loaded; the models
# are about 3.7 GB on disk and the Python environment about 0.8 GB.
check_mac() {
  [ "$(uname -s)" = Darwin ] || die "Larmor runs on macOS only."
  local chip os major mem_gb free_gb
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo Mac)"
  os="$(sw_vers -productVersion)"; major="${os%%.*}"
  mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  free_gb=$(( $(df -k "$HOME" | awk 'NR==2 {print $4}') / 1048576 ))
  printf '  %sWhat Larmor needs%s\n' "$B" "$X"
  [ "$(uname -m)" = arm64 ] || die "Larmor needs an Apple Silicon Mac (M1 or later). This one is $chip."
  [ "$major" -ge 14 ] || die "Larmor needs macOS 14 or later. This Mac has $os."
  ok "$(printf '%-30s' "$chip, macOS $os")" "Apple Silicon, macOS 14 or later"
  if [ "$mem_gb" -lt 8 ]; then
    die "Larmor needs at least 8 GB of memory. This Mac has $mem_gb GB."
  elif [ "$mem_gb" -lt 16 ]; then
    ok "$(printf '%-30s' "$mem_gb GB memory")" "uses about 3 GB while it runs (tight on $mem_gb GB; 16 GB is comfortable)"
  else
    ok "$(printf '%-30s' "$mem_gb GB memory")" "uses about 3 GB while it runs"
  fi
  [ "$free_gb" -ge 6 ] || die "Larmor needs about 5 GB of disk for its voice models. This Mac has $free_gb GB free."
  ok "$(printf '%-30s' "$free_gb GB free disk")" "needs about 5 GB for the voice models"
  printf '\n'
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
  local dom="gui/$(id -u)" i
  launchctl bootout "$dom/$LABEL" 2>/dev/null || true
  # bootout returns before launchd has let go of the job, and bootstrapping again too
  # soon fails with "5: Input/output error". That broke every re-install.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$dom/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  for i in 1 2 3; do
    launchctl bootstrap "$dom" "$PLIST" && return 0
    sleep 1
  done
  return 1
}

uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  say "Larmor app stopped and removed from login items."
  say "Agent configs, the Python environment and downloaded models are untouched."
  say "To remove the MCP server from Claude Code: claude mcp remove larmor -s user"
}

# ── agents ────────────────────────────────────────────────────────────────────
# Every agent gets the MCP server (the voice tools, plus the speaking rules it sends on
# connect) and the larmor skill. Agents with Claude-style hooks (Claude Code, Codex) also
# get the Stop and mid-work hooks. Anything else that speaks MCP works from --print.

AGENTS_SKILLS="$HOME/.agents/skills"   # the shared skills folder Codex and Gemini CLI read
DESKTOP_DIR="$HOME/Library/Application Support/Claude"
ALL_AGENTS="claude desktop codex gemini antigravity"

has_claude()      { command -v claude >/dev/null; }
has_desktop()     { [ -d /Applications/Claude.app ] || [ -d ~/Applications/Claude.app ] || [ -d "$DESKTOP_DIR" ]; }
has_codex()       { command -v codex >/dev/null; }
has_gemini()      { command -v gemini >/dev/null; }
has_antigravity() { command -v agy >/dev/null || [ -d ~/.gemini/antigravity-cli ] || [ -d ~/.gemini/config ]; }

put_skill() {  # skills-dir
  mkdir -p "$1/larmor"
  cp "$SKILL" "$1/larmor/SKILL.md"
}

# Claude Code and Codex read the same hook format, so one merge serves both files.
_hooks() {  # settings-file
  "$PY" - "$1" "$PY" "$DIR" <<'PYEOF'
import json, os, sys
p, py, d = sys.argv[1:]
p = os.path.expanduser(p)
try: c = json.load(open(p))
except FileNotFoundError: c = {}
except ValueError: sys.exit(f"{p} isn't valid JSON, so Larmor left it alone.")
h = c.setdefault("hooks", {})
def add(event, name, entry):
    lst = h.setdefault(event, [])
    lst[:] = [m for m in lst if name not in json.dumps(m)]     # replace, so paths stay current
    lst.append(entry)
cmd = lambda f: f"{py} {d}/hooks/{f}"
# a turn can't end while voice mode is on
add("Stop", "larmor_stop_hook", {"hooks": [{"type": "command", "command": cmd("larmor_stop_hook.py")}]})
# start_voice -> record which session turned voice on, so only that one is held to it
add("PostToolUse", "larmor_claim_hook", {"matcher": "mcp__larmor__start_voice",
    "hooks": [{"type": "command", "command": cmd("larmor_claim_hook.py")}]})
# after every tool call: hand the agent anything the user said while it worked
add("PostToolUse", "larmor_heard_hook", {
    "hooks": [{"type": "command", "command": cmd("larmor_heard_hook.py"), "timeout": 5}]})
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(c, open(p, "w"), indent=2)
PYEOF
}

_json_mcp() {  # file
  "$PY" - "$1" "$PY" "$SERVER" <<'PYEOF'
import json, os, sys
p, py, server = sys.argv[1:]
p = os.path.expanduser(p)
try: c = json.load(open(p))
except FileNotFoundError: c = {}
except ValueError: sys.exit(f"{p} isn't valid JSON, so Larmor left it alone.")
c.setdefault("mcpServers", {})["larmor"] = {"command": py, "args": [server]}
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(c, open(p, "w"), indent=2)
PYEOF
}

install_claude() {
  has_claude || { say "Claude Code: not found, skipping"; return; }
  claude mcp remove larmor -s user >/dev/null 2>&1 || true
  claude mcp add larmor -s user -- "$PY" "$SERVER" >/dev/null
  put_skill ~/.claude/skills
  _hooks ~/.claude/settings.json
  say "Claude Code: voice tools, /larmor skill, hooks"
}

install_desktop() {
  has_desktop || { say "Claude Desktop: not found, skipping"; return; }
  local f="$DESKTOP_DIR/claude_desktop_config.json"
  [ -f "$f" ] && [ ! -f "$f.bak-larmor" ] && cp "$f" "$f.bak-larmor"
  # Desktop has no hooks and no skills folder: the speaking rules arrive with the MCP server.
  _json_mcp "$f" || { say "Claude Desktop: its config isn't valid JSON, left it alone"; return 0; }
  say "Claude Desktop: voice tools (quit and reopen it to load them)"
}

install_codex() {
  has_codex || { say "Codex: not found, skipping"; return; }
  local f=~/.codex/config.toml
  mkdir -p ~/.codex; touch "$f"
  [ -f "$f.bak-larmor" ] || cp "$f" "$f.bak-larmor"
  # Rewrite our block each time. listen() waits up to five minutes for the user to talk,
  # and Codex gives up on a tool after 60 seconds unless told otherwise. Its tools are
  # pre-approved: an approval prompt on every speak() and listen() would end the conversation.
  "$PY" - "$f" "$PY" "$SERVER" <<'PYEOF'
import sys
p, py, server = sys.argv[1:]
out, skip = [], False
for line in open(p).read().splitlines():
    s = line.strip()
    if s.startswith("["):
        skip = s == "[mcp_servers.larmor]" or s.startswith("[mcp_servers.larmor.")
    if not skip:
        out.append(line)
while out and not out[-1].strip():
    out.pop()
out += ["", "[mcp_servers.larmor]", f'command = "{py}"', f'args = ["{server}"]', "tool_timeout_sec = 900",
        'default_tools_approval_mode = "approve"', ""]
open(p, "w").write("\n".join(out))
PYEOF
  put_skill "$AGENTS_SKILLS"
  _hooks ~/.codex/hooks.json
  say "Codex: voice tools, \$larmor skill, hooks (trust them once with /hooks)"
}

install_gemini() {
  has_gemini || { say "Gemini CLI: not found, skipping"; return; }
  _json_mcp ~/.gemini/settings.json
  put_skill "$AGENTS_SKILLS"
  say "Gemini CLI: voice tools, larmor skill"
}

install_antigravity() {
  has_antigravity || { say "Antigravity: not found, skipping"; return; }
  _json_mcp ~/.gemini/config/mcp_config.json
  [ -d ~/.gemini/antigravity-cli ] && _json_mcp ~/.gemini/antigravity-cli/mcp_config.json
  put_skill ~/.gemini/skills
  say "Antigravity: voice tools, larmor skill"
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

# ── which agents ──────────────────────────────────────────────────────────────
# Find the agents on this Mac and let the user pick which ones get Larmor. Asked up
# front with the email, so the long part of the install runs without questions.

agent_name() {
  case "$1" in
    claude) echo "Claude Code" ;; desktop) echo "Claude Desktop" ;; codex) echo "Codex" ;;
    gemini) echo "Gemini CLI" ;;  antigravity) echo "Antigravity" ;;
  esac
}

names_of() {  # "claude codex" -> "Claude Code and Codex"
  local out="" n=0 total=$# id
  for id in "$@"; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then out="$(agent_name "$id")"
    elif [ "$n" -eq "$total" ]; then out="$out and $(agent_name "$id")"
    else out="$out, $(agent_name "$id")"; fi
  done
  printf '%s' "$out"
}

read_key() {  # one keypress from the terminal: up, down, space, enter, a, 1-9, or other
  local k rest
  IFS= read -rsn1 k </dev/tty || { echo quit; return; }
  case "$k" in
    $'\033') IFS= read -rsn2 -t 1 rest </dev/tty || true
             case "$rest" in '[A') echo up ;; '[B') echo down ;; *) echo other ;; esac ;;
    "") echo enter ;;
    " ") echo space ;;
    k) echo up ;; j) echo down ;;
    a|A) echo all ;;
    [1-9]) echo "$k" ;;
    *) echo other ;;
  esac
}

# Arrow keys and space on a real terminal; a typed list of numbers otherwise.
pick_agents() {  # ids...  -> sets AGENTS
  local ids=("$@") n=$# sel=() cur=0 i key mark ptr line
  for ((i = 0; i < n; i++)); do sel[i]=1; done
  printf '  Which agents should get Larmor?\n' >/dev/tty
  if [ "$FANCY" = 1 ]; then
    printf '  %s↑↓ move · space select · enter confirm%s\n' "$D" "$X" >/dev/tty
    printf '\033[?25l' >/dev/tty
    stty -echo </dev/tty 2>/dev/null || true       # a key pressed early can't print over the menu
    while :; do
      for ((i = 0; i < n; i++)); do
        if [ "${sel[i]}" = 1 ]; then mark="${G}◉${X}"; else mark="${D}◯${X}"; fi
        if [ "$i" = "$cur" ]; then ptr="${E}❯${X}"; line="${B}$(agent_name "${ids[i]}")${X}"
        else ptr=" "; line="$(agent_name "${ids[i]}")"; fi
        printf '\r\033[K  %s %s %s\n' "$ptr" "$mark" "$line" >/dev/tty
      done
      key="$(read_key)"
      case "$key" in
        up)    cur=$(( (cur + n - 1) % n )) ;;
        down)  cur=$(( (cur + 1) % n )) ;;
        space) sel[cur]=$(( 1 - sel[cur] )) ;;
        all)   local any=0; for ((i = 0; i < n; i++)); do [ "${sel[i]}" = 0 ] && any=1; done
               for ((i = 0; i < n; i++)); do sel[i]=$any; done ;;
        [1-9]) [ "$key" -le "$n" ] && sel[key-1]=$(( 1 - sel[key-1] )) ;;
        enter) break ;;
        quit)  printf '\033[?25h' >/dev/tty; die "Cancelled." ;;
      esac
      printf '\033[%dA' "$n" >/dev/tty
    done
    printf '\033[%dA\033[2A\033[J\033[?25h' "$n" >/dev/tty   # fold the menu away
    stty echo </dev/tty 2>/dev/null || true
  else
    for ((i = 0; i < n; i++)); do printf '    %d) %s\n' $((i + 1)) "$(agent_name "${ids[i]}")" >/dev/tty; done
    printf '  Numbers to install for, separated by spaces (enter for all): ' >/dev/tty
    IFS= read -r line </dev/tty || die "Cancelled."
    if [ -n "${line// /}" ]; then
      for ((i = 0; i < n; i++)); do sel[i]=0; done
      for key in $line; do
        case "$key" in *[!0-9]*|"") continue ;; esac
        [ "$key" -ge 1 ] && [ "$key" -le "$n" ] && sel[key-1]=1
      done
    fi
  fi
  AGENTS=""
  for ((i = 0; i < n; i++)); do [ "${sel[i]}" = 1 ] && AGENTS="$AGENTS ${ids[i]}"; done
  AGENTS="${AGENTS# }"
}

choose_agents() {
  local found=() id
  printf '\n  %sYour agents%s\n' "$B" "$X"
  for id in $ALL_AGENTS; do "has_$id" && found+=("$id"); done
  case "$target" in
    --no-agents) AGENTS="" ;;
    all)
      if [ -n "${LARMOR_AGENTS:-}" ]; then
        AGENTS="$(printf '%s' "$LARMOR_AGENTS" | tr ',' ' ')"
      elif [ ${#found[@]} -eq 0 ]; then
        AGENTS=""
      elif (: </dev/tty) 2>/dev/null; then
        pick_agents "${found[@]}"
      else
        AGENTS="${found[*]}"                     # nobody to ask: every agent we found
      fi ;;
    *) AGENTS="$target" ;;
  esac
  for id in $AGENTS; do
    case " $ALL_AGENTS " in *" $id "*) ;; *) die "Unknown agent \"$id\". Pick from: ${ALL_AGENTS// /, }." ;; esac
  done
  if [ ${#found[@]} -eq 0 ] && [ "$target" = all ]; then
    printf '  %s·%s No coding agents found. Any agent with MCP can use Larmor: see the end.\n' "$D" "$X"
  else
    for id in $ALL_AGENTS; do
      case " $AGENTS " in
        *" $id "*) ok "$(agent_name "$id")" ;;
        *) case " ${found[*]:-} " in *" $id "*) printf '  %s·%s %s %sskipped%s\n' "$D" "$X" "$(agent_name "$id")" "$D" "$X" ;; esac ;;
      esac
    done
  fi
  printf '\n'
}

wire_agents() {
  local id
  for id in $AGENTS; do "install_$id"; done
}

# ── models ──────────────────────────────────────────────────────────────────────

# The menu-bar app starts fetching the models the moment it launches. Follow it here
# with a progress bar, so "installed" means ready to talk. Ctrl-C leaves it running in
# the background. On a pipe (an agent running us) don't wait: the icon shows progress.
follow_models() {
  MODELS_READY=0
  if [ "$FANCY" != 1 ]; then
    say "  → The voice models (about 3.7 GB) download in the background; the menu-bar icon shows progress."
    return 0
  fi
  if "$PY" - "$G" "$D" "$R" "$X" "${LARMOR_ENGINE_URL:-http://127.0.0.1:8160}" <<'PYEOF'
import json, shutil, sys, time, urllib.request
G, D, R, X, ENGINE = sys.argv[1:6]
SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
W = 20                                           # bar width
out = sys.stdout


def health():
    try:
        with urllib.request.urlopen(f"{ENGINE}/health", timeout=2) as r:
            return json.loads(r.read())
    except Exception:
        return None


def took(t0):
    s = int(time.time() - t0)
    return f"{s // 60}m {s % 60:02d}s" if s >= 60 else (f"{s}s" if s >= 1 else "")


def show(spin, label, parts=()):
    """One status line that always fits the terminal: drop the least useful parts first."""
    cols = shutil.get_terminal_size((80, 24)).columns - 1
    parts = list(parts)
    while True:
        plain = f"  {spin} {label} " + " · ".join(p[1] for p in parts)
        if len(plain) <= cols or not parts:
            break
        parts.pop()
    rich = " · ".join(p[0] for p in parts)
    out.write(f"\r\033[K  {G}{spin}{X} {label} {rich}")
    out.flush()


t0 = time.time(); seen = time.time(); h = None; polled = 0.0; hist = []; i = 0
out.write("\033[?25l")
try:
    while True:
        now = time.time()
        if now - polled >= 0.5:
            h, polled = health(), now
            if h is not None:
                seen = now
        spin = SPIN[i % len(SPIN)]; i += 1
        st = (h or {}).get("state")
        if h is None and now - seen > 90:
            out.write(f"\r\033[K  {R}✗{X} The voice engine didn't start. The menu-bar icon has details.\n")
            sys.exit(4)
        if st == "ready":
            out.write(f"\r\033[K  {G}✓{X} Voice models ready {D}{took(t0)}{X}\n")
            sys.exit(0)
        if st == "error":
            out.write(f"\r\033[K  {R}✗{X} The voice models didn't load: {h.get('detail', '')}\n"
                      f"    {D}The menu-bar icon has details, and Send feedback if it stays stuck.{X}\n")
            sys.exit(4)
        if st == "downloading" and h.get("total_mb"):
            have, total = h.get("downloaded_mb", 0), h["total_mb"]
            if not hist or hist[-1][1] != have:
                hist.append((now, have))
            hist = [p for p in hist if now - p[0] <= 10]
            rate = (hist[-1][1] - hist[0][1]) / (hist[-1][0] - hist[0][0]) if len(hist) > 1 else 0
            frac = min(have / total, 1.0) if total else 0
            fill = int(frac * W)
            bar = f"{G}{'━' * fill}{X}{D}{'─' * (W - fill)}{X}"
            gb = f"{have / 1000:.1f} of {total / 1000:.1f} GB"
            parts = [(f"{bar} {int(frac * 100)}%", "─" * W + " 100%"), (f"{D}{gb}{X}", gb)]
            if rate > 0.5:
                left = (total - have) / rate
                eta = f"about {int(left // 60) + 1} min left" if left >= 60 else f"{int(left) + 1}s left"
                parts.append((f"{D}{eta}{X}", eta))
            show(spin, "Checking the voice models" if have >= total else "Downloading the voice models", parts)
        elif st in ("downloading", "loading"):
            show(spin, "Loading the voice models", [(f"{D}{took(t0)}{X}", took(t0))])
        else:
            show(spin, "Starting the voice engine", [(f"{D}{took(t0)}{X}", took(t0))])
        time.sleep(0.1)
except KeyboardInterrupt:
    out.write(f"\r\033[K  {D}·{X} Still downloading in the background. The menu-bar icon shows the progress.\n")
    sys.exit(3)
finally:
    out.write("\033[?25h")
    out.flush()
PYEOF
  then MODELS_READY=1; fi
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────────

finish() {
  local k=0 id
  num() { k=$((k + 1)); printf '  %s%d%s  ' "$E" "$k" "$X"; }
  if [ "$MODELS_READY" = 1 ]; then
    printf '\n  %sLarmor is ready.%s\n\n' "$B" "$X"
  else
    printf '\n  %sLarmor is installed.%s\n\n' "$B" "$X"
    num; printf 'The menu-bar icon is still fetching the voice models (about 3.7 GB,\n'
    printf '     first time only). When it turns into a plain waveform, you'\''re ready.\n'
  fi
  num; printf 'Open a new session in your agent and start voice mode:\n'
  for id in $AGENTS; do
    case "$id" in
      claude)  printf '       %-15s %s/larmor%s\n' "Claude Code" "$B" "$X" ;;
      desktop) printf '       %-15s quit and reopen it, then say "voice mode"\n' "Claude Desktop" ;;
      codex)   printf '       %-15s %s$larmor%s\n' "Codex" "$B" "$X" ;;
      *)       printf '       %-15s say "voice mode"\n' "$(agent_name "$id")" ;;
    esac
  done
  if [ -n "$AGENTS" ]; then
    printf '       %sAny other agent with MCP: add the output of%s\n' "$D" "$X"
  else
    printf '       %sFor any agent with MCP, add the output of%s\n' "$D" "$X"
  fi
  printf '       %s~/.larmor/app/install.sh --print to its MCP settings, then say "voice mode".%s\n' "$D" "$X"
  num; printf 'When macOS asks for microphone access, allow it.\n\n'
  printf '  %sHeadphones or speakers both work, and you can talk over it.%s\n' "$D" "$X"
  case " $AGENTS " in *" codex "*) printf '  %sIn Codex, run /hooks once and trust Larmor'\''s hooks.%s\n' "$D" "$X" ;; esac
  printf '  %sNo icon? A full menu bar hides it: hold ⌘ and drag other icons away.%s\n' "$D" "$X"
  printf '  %sSomething off? Menu-bar icon → Send feedback.%s\n\n' "$D" "$X"
}

main() {
  target="${1:-all}"
  case "$target" in
    --print)     json_config; exit 0 ;;
    --uninstall) uninstall; exit 0 ;;
    all|claude|desktop|gemini|antigravity|codex|--no-agents) ;;
    *) die "usage: $0 [claude|desktop|codex|gemini|antigravity|--no-agents|--uninstall|--print]" ;;
  esac
  trap '[ "$FANCY" = 1 ] && printf "\033[?25h"; stty echo </dev/tty 2>/dev/null || true' EXIT
  mkdir -p "$HOME/.larmor"; : > "$LOG"
  banner
  check_mac
  get_email
  choose_agents
  printf '  %sInstalling%s\n' "$B" "$X"
  if [ -n "${LARMOR_FETCHED:-}" ]; then ok "Downloaded Larmor" "$LARMOR_FETCHED"; fi
  if ! command -v uv >/dev/null; then
    step "Installing uv, the Python package manager" install_uv
    export PATH="$HOME/.local/bin:$PATH"
  fi
  step "Setting up Python and the speech libraries (about 800 MB)" install_runtime
  step "Adding the menu-bar app (starts at login)" install_app
  if [ -n "$AGENTS" ]; then
    # shellcheck disable=SC2086
    STEP_SHOW=1 step "Connecting $(names_of $AGENTS)" wire_agents
  fi
  follow_models
  finish
}

[ -n "${LARMOR_NO_MAIN:-}" ] || main "$@"
