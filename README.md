# Larmor

Talk to your coding agent, and have it talk back while it works.

Larmor gives any agent that speaks MCP a voice and ears: Claude Code, Claude Desktop, Codex,
Gemini CLI, Antigravity, or anything else that can add an MCP server. You can talk over it and it stops; say
"mm-hmm" and it carries on. What you say while it's busy editing files reaches it mid-task.
Everything runs on your Mac. No audio leaves it, and there are no API keys.

[larmor.dev](https://larmor.dev)

## Install

Apple Silicon Mac, macOS 14 or later, about 6 GB of free disk. The engine uses about 3 GB of
memory while it runs; 16 GB Macs are comfortable, 8 GB works but is tight.

```bash
curl -fsSL https://larmor.dev/install.sh | bash
```

That one-liner downloads this repo as a tarball from larmor.dev and runs [`install.sh`](install.sh).
If you'd rather read it first, or run it straight from source:

```bash
git clone https://github.com/naveenvasou/larmor.git ~/.larmor/app
~/.larmor/app/install.sh
```

The installer asks for your email, finds the agents on your Mac and lets you pick which ones get
Larmor, then downloads about 3.7 GB of models with a progress bar. The first time you use it,
macOS asks your terminal for microphone access.

## Start talking

Open a new session in your agent:

- **Claude Code:** type `/larmor`
- **Claude Desktop:** quit and reopen it (⌘Q), then ask for "voice mode" in a new chat
- **Codex:** type `$larmor`. Run `/hooks` once and trust Larmor's hooks.
- **Anything else:** ask it for "voice mode"

For an agent the installer doesn't know, add the output of `~/.larmor/app/install.sh --print`
to its MCP settings.

## What the installer changes on your Mac

| Where | What |
|---|---|
| `~/.larmor/` | The app, its Python environment, your email, and logs |
| `~/Library/LaunchAgents/dev.larmor.menubar.plist` | The menu-bar app, started at login. It runs the speech engine on `127.0.0.1:8160` |
| `~/.cache/huggingface/hub/` | The voice models (Parakeet, Chatterbox) |
| `~/.local/bin/uv` | [uv](https://github.com/astral-sh/uv), only if you don't have it already |
| Claude Code | `claude mcp add larmor -s user`, the skill in `~/.claude/skills/larmor`, hooks in `~/.claude/settings.json` |
| Claude Desktop | `mcpServers.larmor` in `~/Library/Application Support/Claude/claude_desktop_config.json` (backed up once to `claude_desktop_config.json.bak-larmor`) |
| Codex | A `[mcp_servers.larmor]` block in `~/.codex/config.toml` (backed up once to `config.toml.bak-larmor`), hooks in `~/.codex/hooks.json`, the skill in `~/.agents/skills/larmor` |
| Gemini CLI | `mcpServers.larmor` in `~/.gemini/settings.json`, the skill in `~/.agents/skills/larmor` |
| Antigravity | `mcpServers.larmor` in `~/.gemini/config/mcp_config.json`, the skill in `~/.gemini/skills/larmor` |

Only the agents you pick are touched, and only Larmor's own entries in their config files.
A config file that isn't valid JSON is left alone.

The hooks are small Python scripts in [`hooks/`](hooks). One keeps a voice turn from ending
without listening, one records which session turned voice mode on, and one hands the agent
anything you said while it was working. They do nothing in sessions where voice mode is off.

## What leaves your Mac

- **Your email**, once, at install. It's how you hear about updates while Larmor is in beta.
- **Feedback**, only if you type it into "Send feedback…" in the menu bar.

Both go to one small endpoint whose entire code is [`backend/signup.py`](backend/signup.py).
Nothing else is sent: no audio, no transcripts, no usage data. The only other network traffic is
downloading the installer, Python packages and the models.

## How it works

- **Ears:** Apple's VoiceProcessingIO echo canceller, Silero VAD, Smart Turn v3 for end-of-turn,
  and Parakeet (MLX) for speech-to-text.
- **Voice:** Chatterbox Turbo (MLX), played through the same echo canceller, so the mic hears you
  and not the agent.
- **Interruptions:** your voice pauses playback at once. Keep talking, or say something real like
  "stop", and it stops. A backchannel like "mm-hmm" resumes the sentence.
- **Talk while it works:** what you say mid-task reaches the agent with its next spoken progress
  update, in any agent. In Claude Code and Codex it also arrives after the next tool call, usually
  within seconds.
- **One session at a time:** voice mode belongs to the session that turned it on. Your other
  terminals behave normally.
- **Lets go of the mic:** voice mode switches itself off after 10 minutes without the agent
  using it, or 20 minutes of nobody speaking, so a forgotten chat can't keep your mic open.

The audio front end is a small Swift program, [`native/larmor_audio.swift`](native/larmor_audio.swift).
The repo ships it prebuilt; to build it yourself:

```bash
cd native && cp larmor_audio.swift main.swift && swiftc -O main.swift mic_arbiter.swift -o larmor_audio && rm main.swift
```

## Uninstall

```bash
~/.larmor/app/install.sh --uninstall   # stops the app and removes the login item
claude mcp remove larmor -s user       # Claude Code
```

Then, for the agents you set up, delete the `larmor` skill folders and Larmor's entries in the
config files listed above. To free the disk space, delete `~/.larmor` and the Parakeet and
Chatterbox folders in `~/.cache/huggingface/hub`.

Can't see the menu-bar icon? A full menu bar hides new icons. Hold ⌘ and drag some out.

## Licence

[MIT](LICENSE). The bundled models and the ones downloaded at first launch keep their own
licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
