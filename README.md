# ServitorAI

A Warhammer × Catppuccin themed macOS menu-bar AI chat app. Fast, keyboard-first, and backed by a warm `pi --mode rpc` process.

![ServitorAI screenshot](docs/screenshot.png)

## What it is

- ⌘⇧A (or your chosen global hotkey) opens a borderless panel from the menu bar.
- Type, press ↵, get answers from a local/remote LLM via `pi`.
- Markdown, code blocks, clickable links, and a dark, brass-and-machine-teal aesthetic.
- No web UI, no Electron, no bloat. Just Swift + AppKit + your own model.

## Requirements

- macOS 14+
- [pi](https://github.com/earendil-works/pi-coding-agent) installed and configured with at least one usable model/auth provider

## Install

```bash
git clone https://github.com/hanjoe/ServitorAI.git
cd ServitorAI
./install.sh
```

ServitorAI shares pi's existing model configuration and sign-in. In a terminal, start `pi` and run `/login` to sign in to a supported provider (for example, GitHub Copilot). Then launch ServitorAI. On first setup, ServitorAI looks for installed pi extensions that advertise a web-search tool and asks before loading one. Review the extension code and trust its source before enabling it; you can leave search off and change the choice later with **Configure Web Search…**. It asks pi which models are currently usable, puts configured favourites first, and falls back to a signed-in model if its configured default is unavailable. If no models are available, sign in or configure a provider in pi, then relaunch ServitorAI.

Credentials stay in pi's own auth/configuration, such as `~/.pi/agent/auth.json`; ServitorAI does not copy OAuth tokens or implement a separate login flow. Keep pi's auth files private and never commit them.

### Ollama Cloud (optional)

Ollama Cloud is an OpenAI-compatible endpoint. Add it to `~/.pi/agent/models.json` if it is not already configured. Store the API key in macOS Keychain Access as a generic password with service `servitorai-ollama` and account equal to your macOS username. Then use pi's command-based key lookup in the provider config, so the key is not written in `models.json`:

```json
{
  "providers": {
    "ollama-cloud": {
      "baseUrl": "https://ollama.com/v1",
      "api": "openai-completions",
      "apiKey": "!security find-generic-password -s servitorai-ollama -w",
      "models": [
        { "id": "deepseek-v4.1-flash:cloud" },
        { "id": "deepseek-v4-pro:cloud" }
      ]
    }
  }
}
```

Pi runs the Keychain lookup when it needs the key. macOS may ask to allow pi to access that Keychain item; review the prompt and choose **Always Allow** only if you trust the installed pi binary. This setup is optional—any provider already configured and authenticated in pi can be used.

### Optional Proton Pass integration

Existing ServitorAI configs may still use `pass://` references if `pass-cli` is installed and logged in:

```json
"env": { "OLLAMA_API_KEY": "pass://YourVault/YourItemTitle/password" }
```

ServitorAI resolves these once at startup and passes the resolved value only to the pi child. Proton Pass is not required; omit `env` when using pi's own authentication/configuration.

Load the LaunchAgent if you want it auto-starting at login:

```bash
launchctl load ~/Library/LaunchAgents/com.johanneswitt.servitorai.plist
```

## Default keybinds

All shortcuts are editable in `~/.config/servitorai/keybinds.conf` (open with ⌘,).

| Shortcut | Action |
|----------|--------|
| ⌘⇧A | Show/hide panel |
| ↵ | Submit question |
| ⌃C | Copy last answer |
| ⌃⌥C | Copy last fenced code block |
| ⌃⇧1 … ⌃⇧0 | Copy code or open link at that visible target number |
| ⌃/ | Search transcript; n/N next/previous match |
| V, then j/k, y | Select lines, then copy in transcript copy mode |
| PgUp / PgDn | Scroll transcript
| ⌃↵ / ⌘↵ | Paste answer to the previous app |
| ⌃R | Regenerate |
| ⌃N | New chat |
| ⌃[ / ⌃] | Older / newer chat |
| ⌃M / ⌃1-9 | Cycle / pick model |
| ⌘, | Open keybinds config in `$EDITOR` |
| Esc / ⌘W | Hide panel |

`keybinds.conf` is a plain text file with comments. Edit, save, and the app reloads immediately.

## Agent tool boundaries

The panel starts as a conversational chat, not an autonomous coding agent. Its child process is limited to read-only file reading/listing and, optionally, `web_search` when an installed pi search extension is explicitly approved. pi does not provide a general web-search tool in its default built-in tools; without an installed and approved search extension, ServitorAI simply runs without web search. Shell, file edits/writes, MCP, and Orbit are disabled.

## Configuration

See `config.example.json` for app preferences. Its `provider`/`model` and `models` entries are preferences/favourites, not credentials or a required provider install; pi's authenticated model catalog determines the actual choices. You can change the favourite order in `config.json`. The app does not require an `OLLAMA_API_KEY` when another pi provider is available.

## License

MIT — see [LICENSE](LICENSE).

Fonts are [Press Start 2P](https://fonts.google.com/specimen/Press+Start+2P) and [VT323](https://fonts.google.com/specimen/VT323), licensed under the SIL Open Font License (`Assets/Fonts/OFL-*.txt`).
