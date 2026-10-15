# Claude Sessions

English | [한국어](README.ko.md)

A small always-on-top desktop widget for Windows and macOS that shows all your Claude Code sessions at a glance: which ones are working, which ones are done and waiting for you, and how full each context window is.

![demo](docs/demo.gif)

## Features

- Sessions for any day: title, tokens used, elapsed time, context usage bar
- Status: working / done (waiting for input) / waiting for permission / closed
- Pin important sessions to the top
- Remove sessions you don't need from the list, and bring them back from the eye button
- Collapse the widget down to its title bar, and drag the title bar to move it
- Calendar to browse previous days
- Click a session to jump to it in VS Code
- Single file, nothing to install. English or Korean UI, following your system language

## Requirements

- [Claude Code](https://claude.com/claude-code) (CLI or VS Code extension)
- Windows 10 / 11: nothing else (uses the built-in Windows PowerShell 5.1). To jump to a session, the VS Code `code` command must be on your PATH
- macOS 13+: Xcode Command Line Tools (`xcode-select --install`)

## Windows

### Install

In PowerShell:

```powershell
irm https://github.com/yeonizin/claude-session-board/releases/latest/download/session-board.ps1 -OutFile "$HOME\.claude\session-board.ps1"
```

Or download `session-board.ps1` from the [latest release](https://github.com/yeonizin/claude-session-board/releases/latest) and put it anywhere.

### Run

```powershell
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "$HOME\.claude\session-board.ps1"
```

To add a desktop shortcut, run this in PowerShell. To start it with Windows instead, change `'Desktop'` to `'Startup'`.

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\Claude Sessions.lnk")
$s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HOME\.claude\session-board.ps1`""
$s.WindowStyle = 7
$s.Save()
```

## macOS

```sh
curl -fsSL https://github.com/yeonizin/claude-session-board/releases/latest/download/session-board.swift -o ~/.claude/session-board.swift
nohup swift ~/.claude/session-board.swift >/dev/null 2>&1 &
```

The first launch takes a few seconds while Swift compiles the script.

## Reading the widget

| Mark | Meaning |
|---|---|
| Blue dot | Claude is working |
| Check | Claude finished and is waiting for your input |
| Warning | Claude is waiting for a tool permission |
| Faded circle | The session window is closed |
| `312k tok` | Tokens used by the session (cache reads excluded) |
| `1h 42m` | Time from the first message to the latest activity |
| Bar and `%` | Context window usage. Near 100%, Claude Code compacts the conversation |

## How it works

It only reads files Claude Code already keeps on your machine. **It makes no network requests.**

| File | Used for |
|---|---|
| `~/.claude/projects/*/*.jsonl` | Session title, token usage, timing, working folder |
| `~/.claude/sessions/*.json` | Which sessions are running and their status |

The only file it writes is `~/.claude/session-board.json`, which stores your pinned and removed sessions.
If `CLAUDE_CONFIG_DIR` is set, that folder is used instead of `~/.claude`.

Each version of the widget is one readable script. Please look through it before running it.

## Limitations

- It relies on Claude Code's **internal file formats**, which may change in a Claude Code update.
- Claude Code deletes transcripts older than 30 days by default, so older days show nothing. You can raise `cleanupPeriodDays` in your Claude Code settings.
- Tokens and time are totals for the whole session, not just the selected day.
- The context window size is not recorded in transcripts, so any session that has gone over 200k tokens is treated as a 1M window.

This is a personal project and is not affiliated with Anthropic.

## License

[MIT](LICENSE)
