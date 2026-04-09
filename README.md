# Clipped

[![Release](https://github.com/mcclowes/clipped/actions/workflows/release.yml/badge.svg)](https://github.com/mcclowes/clipped/actions/workflows/release.yml)

A lightweight, native macOS clipboard manager that lives in your menu bar, fits the platform aesthetic, and gets out of the way.

Clipped keeps a searchable history of everything you copy — text, images, links, code — so you never lose something you copied earlier. No Dock icon, no clutter, just a quiet menu bar panel available whenever you need it.

## Install

**Homebrew** (recommended):

```bash
brew install mcclowes/clipped/clipped
```

**Manual download:** Grab the latest `Clipped.zip` from [GitHub Releases](https://github.com/mcclowes/clipped/releases), unzip, and drag Clipped to your Applications folder.

Requires **macOS 15.0 (Sequoia)** or later.

## Getting started

1. Launch Clipped — it appears as an icon in your menu bar (no Dock icon).
2. Copy things as you normally would. Clipped automatically tracks your clipboard.
3. Press **`⌘⇧V`** to open the Clipped panel from anywhere, or click the menu bar icon.
4. Click any item to copy it back to your clipboard.

## Features

- **Clipboard history** — Automatically tracks what you copy, with configurable history size
- **Format preservation** — Rich text, URLs, images, and code snippets retain their formatting
- **Global hotkey** — Press `⌘⇧V` to open Clipped from any app
- **Search & filter** — Find past items by text or filter by content type (text, images, links, etc.)
- **Pinned items** — Pin frequently used snippets so they always stay at the top
- **Secure mode** — Automatically skips or auto-expires entries from password managers
- **Paste as plain text** — Strip formatting and paste matching the destination style
- **Markdown conversion** — Convert rich text items to Markdown with one click
- **Link previews** — Automatically fetches page titles for URLs
- **Screenshot capture** — Detects new screenshots and adds them to your history
- **Sticky notes** — Pin any item as a floating note on your desktop
- **Export** — Merge and copy multiple items at once
- **Persistence** — Optionally keep your history across app restarts
- **Launch at login** — Start Clipped automatically when you log in

## Privacy & security

Clipped runs entirely on your Mac. No data is sent anywhere — your clipboard history stays local, stored in `~/Library/Application Support/Clipped/`. Sensitive entries from password managers can be automatically skipped or expired.

## Building from source

If you'd like to build Clipped yourself:

```bash
make generate  # Generate Xcode project via XcodeGen
make build     # Build the app
make run       # Build and launch
make test      # Run tests
```

Requires Xcode 16+ and Swift 6. See [CLAUDE.md](CLAUDE.md) for project structure and architecture details.
