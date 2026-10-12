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
- [pi](https://github.com/earendil-works/pi-coding-agent) installed and on your PATH
- An API key for your chosen provider (Ollama Cloud, OpenAI, etc.)

## Install

```bash
git clone https://github.com/hanjoe/ServitorAI.git
cd ServitorAI
./install.sh
```

Then put your key in `~/.config/servitorai/config.json`:

```json
{
  "model": "ollama-cloud/deepseek-v4.1-flash",
  "env": {
    "OLLAMA_API_KEY": "your-key-here"
  }
}
```

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
| ⌃⇧1 … ⌃⇧0 | Copy/open the numbered target visible in the viewport |
| ⌃↵ / ⌘↵ | Paste answer to the previous app |
| ⌃R | Regenerate |
| ⌃N | New chat |
| ⌃[ / ⌃] | Older / newer chat |
| ⌃M / ⌃1-9 | Cycle / pick model |
| ⌃, | Open keybinds config in `$EDITOR` |
| Esc / ⌘W | Hide panel |

`keybinds.conf` is a plain text file with comments. Edit, save, and the app reloads immediately.

## Configuration

See `config.example.json` for the full shape. Only the `OLLAMA_API_KEY` (or your provider's equivalent) is required.

## License

MIT — see [LICENSE](LICENSE).

Fonts are [Press Start 2P](https://fonts.google.com/specimen/Press+Start+2P) and [VT323](https://fonts.google.com/specimen/VT323), licensed under the SIL Open Font License (`Assets/Fonts/OFL-*.txt`).
