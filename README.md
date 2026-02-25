# ClaudeBattery 🔋

A lightweight macOS menu bar app that shows your [Claude Code](https://claude.ai/code) token usage as a battery-style indicator — just like the native macOS battery widget.

![Menu bar showing battery icon and percentage](https://img.shields.io/badge/platform-macOS%2013%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## How it works

ClaudeBattery first tries to read usage data directly from Anthropic's servers using the OAuth token that Claude Code stores in your macOS Keychain. This gives you the exact same numbers shown on the claude.ai settings page.

```
Keychain (Claude Code OAuth token)  →  api.anthropic.com/api/oauth/usage  →  menu bar icon
```

If no valid OAuth token is found, it falls back to estimating usage from local JSONL logs:

```
~/.claude/projects/**/*.jsonl  →  parse tokens + cost  →  menu bar icon
```

No credentials to configure — ClaudeBattery reuses the token Claude Code already stored.

## Features

- **Battery icon** in the menu bar, color-coded by remaining capacity
  - 🟢 Green — plenty left (> 25%)
  - 🟠 Orange — getting low (10–25%)
  - 🔴 Red — nearly empty (< 10%)
- **Server-synced stats** — pulls real utilization from Anthropic's API (same source as claude.ai)
- **5-hour and 7-day usage** displayed side by side
- **Plan detection** — reads your subscription type (Pro / Max) from the Keychain automatically
- **Countdown** to next 5-hour reset
- **Auto-refresh** every 60 seconds; manual refresh with ⌘R
- **Launch at Login** toggle built into the popover
- **No Dock icon** — lives purely in the menu bar

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)
- Claude Code installed and signed in (for OAuth sync)

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

**OAuth mode** (when Claude Code is signed in):
```
🔋 ClaudeBattery          92% remaining • Pro
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5h usage       8% used
7d usage       59% used
Resets in      3h 12m
Updated        11:42 AM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Launch at Login  ●
↺ Refresh                    ✕ Quit
```

**Fallback mode** (local JSONL estimate):
```
🔋 ClaudeBattery          69% remaining
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
API cost       $3.45 / $5.00
Tokens (in+out) 5,520
Resets in      2h 14m
Updated        11:42 AM

5h budget   [ Pro (~$5) | Max 5× (~$25) | Max 20× (~$100) ]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Launch at Login  ●
↺ Refresh                    ✕ Quit
```

## Keychain access

On first launch, macOS will show a prompt:

> *"ClaudeBattery" wants to use the "Claude Code-credentials" item from your login keychain.*

Click **Always Allow**. ClaudeBattery only reads the token — it never modifies it or uses it for anything other than the usage API call.

## How the fallback estimation works

When no OAuth token is available, ClaudeBattery estimates usage from local files:

1. Scan all `.jsonl` files under `~/.claude/projects/`
2. Extract token counts from every `assistant` message and compute cost using Anthropic's published per-model rates
3. Sort by timestamp and group into 5-hour blocks (new block when gap > 5 hours)
4. Sum cost in the most recent block; if the block's window has expired, show 0

## Project structure

```
Sources/
  ClaudeBatteryApp.swift  — App entry point + menu bar label
  UsageMonitor.swift      — Keychain reading, OAuth API, JSONL fallback
  MenuContent.swift       — Popover UI
Info.plist                — LSUIElement (no Dock icon)
Makefile                  — Build, run, install targets
```

## License

MIT
