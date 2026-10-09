# Larmor

Talk to your terminal coding agent, and have it talk back while it works.

Larmor gives any coding agent that speaks MCP a voice and ears through a small MCP server: `speak`, `listen`, `start_voice`, `end_voice`, `voice_status`. You can talk over it
and it stops; say "mm-hmm" and it carries on. Everything runs on your Mac. No audio leaves it,
and there are no API keys.

## Install

Apple Silicon Mac, macOS 14 or later, about 5 GB of disk. The engine uses about 3 GB of memory
while it runs; 16 GB Macs are comfortable, 8 GB works but is tight.

```bash
curl -fsSL https://larmor.dev/install.sh | bash
```

That sets up a Python environment, a menu-bar app that starts at login, and the MCP server and
skill for every agent it finds (Claude Code, Codex, Gemini CLI, Antigravity), plus hooks where the
agent supports them (Claude Code, Codex). For any other agent, add the output of
`~/.larmor/app/install.sh --print` to its MCP settings. The first launch downloads about 3.7 GB of models in the
background. The menu-bar icon shows the percentage and turns into a plain waveform when ready.

Then open a new session and type `/larmor` in Claude Code or `$larmor` in Codex, or ask any agent
for "voice mode". In Codex, run `/hooks` once and trust Larmor's hooks.
The first time, macOS asks your terminal for microphone access.

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

## Uninstall

```bash
~/.larmor/app/install.sh --uninstall   # stops the app and removes the login item
claude mcp remove larmor -s user
```

Can't see the icon? A full menu bar hides new icons. Hold ⌘ and drag some out.
