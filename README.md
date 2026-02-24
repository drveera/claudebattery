# ClaudeBattery 🔋

A lightweight macOS menu bar app that shows your [Claude Code](https://claude.ai/code) token usage as a battery-style indicator — just like the native macOS battery widget.

![Menu bar showing battery icon and percentage](https://img.shields.io/badge/platform-macOS%2013%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## How it works

Claude Code writes a JSONL log for every conversation under `~/.claude/projects/`. ClaudeBattery reads those files directly — **no credentials, no network calls, no API keys required**.

It finds all assistant messages from the current 5-hour billing window, sums their token counts, and displays the result as a draining battery.

```
~/.claude/projects/**/*.jsonl  →  parse tokens  →  menu bar icon
```

## Features

- **Battery icon** in the menu bar, color-coded by remaining capacity
  - 🟢 Green — plenty left (> 25%)
  - 🟠 Orange — getting low (10–25%)
  - 🔴 Red — nearly empty (< 10%)
- **Countdown** to next reset (5-hour rolling window)
- **Token counts** — used vs. your plan limit
- **Plan picker** — switch between Pro / Max 5× / Max 20× in one click
- **Auto-refresh** every 60 seconds; manual refresh with ⌘R
- **Launch at Login** toggle built into the popover
- **No Dock icon** — lives purely in the menu bar

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build & install

```bash
git clone https://github.com/drveera/claudebattery.git
cd claudebattery

make run      # build and launch immediately
make install  # copy to /Applications
```

### Launch at Login

1. Run `make install` to place the app in `/Applications`
2. Open the menu bar popover and flip the **Launch at Login** toggle

That's it — macOS will start ClaudeBattery automatically on every login. Toggle it off the same way to disable.

> **Note:** Register the login item from the app's final location. If you move `ClaudeBattery.app` after enabling the toggle, flip it off and back on so macOS picks up the new path.

## Usage

Click the battery icon in the menu bar to see:

```
🔋 ClaudeBattery          69% remaining
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Tokens used    5,520 / 8,000
Resets in      2h 14m
Updated        11:42 AM

Plan limit  [ Pro (~8k) | Max 5× | Max 20× ]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Launch at Login  ●
↺ Refresh                    ✕ Quit
```

Set your plan limit once with the picker — it's saved automatically.

## How the 5-hour window is calculated

Anthropic's Claude Code billing resets on a **rolling 5-hour window** that starts with your first message in a session. ClaudeBattery replicates this locally:

1. Scan all `.jsonl` files under `~/.claude/projects/`
2. Extract `input_tokens + output_tokens` from every `assistant` message
3. Sort by timestamp and group into blocks — a new block starts whenever there's a gap of more than 5 hours between messages
4. Sum the tokens in the most recent block; if that block's 5-hour window has already expired, show 0

## Project structure

```
Sources/
  ClaudeBatteryApp.swift  — App entry point + menu bar label
  UsageMonitor.swift      — JSONL parsing and window calculation
  MenuContent.swift       — Popover UI
Info.plist                — LSUIElement (no Dock icon)
Makefile                  — Build, run, install targets
```

## License

MIT
