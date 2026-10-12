# ServitorAI

A menu-bar **quick chat** for macOS, themed as a Warhammer 40k Adeptus Mechanicus
**servitor** crossed with the **Catppuccin Mocha** palette. It's backed by a warm
`pi --mode rpc` process so responses don't pay agent boot-up cost, and runs in
pure chat mode (`--no-tools`) — you are the Omnissiah, it answers.

## What it does

- **⌘⇧A** toggles a floating chat panel (Carbon hotkey — no Accessibility permission needed).
- **Streams** answers as they're generated (sub-second time-to-first-token with a fast model).
- **Model switch** — click the model button or press **⌘M** to cycle through your curated list.
- **Multi-turn context** — follow-ups see prior messages.
- **New chat** (**⌘N** / "New") resets via pi's `new_session`.
- **Recent chats** — ☰ button or menu bar menu lists the last 3; **⌘[ / ⌘]** navigate.
- **Quick copy** — **⌘⇧C** or the ⧉ button copies the last answer; output is selectable for normal copy.
- **Regenerate** — **⌘R** re-asks the last question.
- **Preheated + self-healing** — one long-lived `pi --mode rpc` child; the app auto-restarts it if it exits.

## Theme

"Servitor" — Catppuccin Mocha base (`#1e1e2e`) with Mechanicus accents:

- **Mars red** (`#f38ba8`) — the accent / header.
- **Brass** (`#fab387`) — the Omnissiah's words.
- **Machine-spirit teal** (`#94e2d5`) — the servitor's replies.
- Monospace labels for the techno-gothic feel.

## How it works

The app owns a single warm `pi` child:

```
pi --mode rpc --no-tools --no-extensions --no-skills --no-prompt-templates \
   --no-context-files --no-mcp --thinking off \
   --provider <provider> --model <model> \
   --system-prompt <persona> --session-dir ~/.config/servitorai/sessions
```

Prompts go over JSON-RPC on stdin/stdout; streaming text arrives as
`text_delta` events and completion as `agent_settled`. Sessions are persisted by
pi (`.jsonl`) with lightweight `.qai.json` sidecars for the "recent chats" list.

## Build & install

```sh
./install.sh
```

Then edit `~/.config/servitorai/config.json` to set `env.OLLAMA_API_KEY` (required
when auto-starting at login, where the key is not otherwise in the environment):

```sh
launchctl load ~/Library/LaunchAgents/com.johanneswitt.servitorai.plist
```

## Configuration (`~/.config/servitorai/config.json`)

| key | meaning |
|-----|---------|
| `provider` / `model` | pi provider + default model (default `ollama-cloud` / `deepseek-v4.1-flash:cloud`) |
| `models` | curated list for the in-app switcher — `provider`, `modelId`, `label` |
| `thinking` | pi `--thinking` level (`off` = lowest latency) |
| `systemPrompt` | the servitor persona |
| `env` | extra env vars injected into the pi child (e.g. provider API key) |

Fast-model notes (measured warm time-to-first-token):

- `github-copilot` / `claude-haiku-4.5` — ~0.6s, no env key needed (OAuth stored in `~/.pi/agent/auth.json`).
- `ollama-cloud` / `deepseek-v4.1-flash:cloud` — ~0.5–0.7s, needs `OLLAMA_API_KEY`.

## Shortcuts

All shortcuts are real NSMenu key equivalents, ctrl-based by default, and fully rebindable — press ⌃, (Settings) to record new combos for any action (Esc cancels, right-click resets to default).

| action | default key |
|--------|--------------|
| Toggle panel (global) | ⌘⇧A |
| Submit | Enter |
| Cancel / hide | Esc |
| Actions menu | ⌃K |
| Settings | ⌘, |
| Copy last answer | ⌃C |
| Copy last code block | ⌃⌥C |
| Copy selection (native) | ⌘C |
| Paste answer into previous app | ⌃↵ |
| Regenerate | ⌃R |
| Regenerate with next model | ⌃⇧R |
| New chat | ⌃N |
| Previous / next chat | ⌃[ / ⌃] |
| Cycle model | ⌃M |
| Model picker menu | ⌃⇧M |
| Pick model 1–9 | ⌃1 … ⌃9 |
| Recent chats | ⌃⇧H |
| Focus input | ⌃L |
| Hide panel | ⌃⇧W |
| Quit | ⌃Q |

Typing while the transcript is focused jumps back to the input automatically.
