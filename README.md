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
3. Press **`⌥C` (Option+C)** to open the Clipped panel from anywhere, or click the menu bar icon. You can change the shortcut in Settings.
4. Click any item to copy it back to your clipboard.

## Features

- **Clipboard history** — Automatically tracks what you copy, with configurable history size
- **Format preservation** — Rich text, URLs, images, and code snippets retain their formatting
- **Global hotkey** — Press `⌥C` (Option+C) to open Clipped from any app
- **Search & filter** — Find past items by text or filter by content type (text, images, links, etc.)
- **Pinned items** — Pin frequently used snippets so they always stay at the top
- **Secure mode** — Automatically skips or auto-expires entries from password managers
- **Paste as plain text** — Strip formatting and paste matching the destination style
- **Markdown conversion** — Convert rich text items to Markdown with one click
- **Link previews** — Automatically fetches page titles for URLs
- **Screenshot capture** — Capture selections, windows, or screens directly to the clipboard, or detect screenshots saved by macOS
- **Sticky notes** — Pin any item as a floating note on your desktop
- **Export** — Merge and copy multiple items at once
- **Persistence** — Off by default; enable "Persist history across reboots" in Settings → General to keep your history across app restarts
- **Encrypted at rest** — When persistence is enabled, saved history and cached images use authenticated encryption with a key held in your login Keychain
- **Launch at login** — Start Clipped automatically when you log in

## Privacy & security

Watched screenshots go to history and onto your clipboard by default, so a capture is ready to paste. Turn off "Copy captured screenshots to clipboard" under Settings → General → Screenshots to keep them in history without changing your clipboard. Detection uses macOS screenshot metadata, so ordinary images in the watched folder are ignored.

Clipboard processing and history storage happen on your Mac. Link previews are enabled by default and make requests to copied websites and their preview-image servers. Turn off "Fetch link previews" in the Privacy section of Settings → General to keep copied URLs local.

- **Local history** — Persistence is off by default. When enabled, history is saved in `~/Library/Application Support/Clipped/`.
- **Encrypted storage** — When persistence is enabled, `history.enc` and cached clipboard images are encrypted with ChaCha20-Poly1305. The 256-bit key is created when encrypted storage is first used and stored in your login Keychain. Access follows the Keychain's lock state and item permissions; locking the screen does not necessarily lock the login Keychain.
- **Secure mode** — Entries from password managers can be automatically skipped or expired.
- **No telemetry, no sync** — Clipped has no telemetry or cloud-sync component. Link previews still make the requests described above.

If saved history can't be opened, choose **Later** to keep using Clipped for the current session. Saving stays paused until **Retry** succeeds or you choose **Start fresh**, which discards the saved history.

### Upgrading from plaintext storage

When persisted history is loaded, Clipped migrates older `history.json` files and plaintext image caches to encrypted storage. Existing Time Machine snapshots and other backups taken before the upgrade may still contain plaintext; the upgrade cannot rewrite those copies. If `history.json` cannot be migrated, Clipped keeps it for recovery. Failed image migrations keep the original plaintext images usable and retry on later loads or saves; those originals are deleted only after their encrypted replacements are written successfully.

## Building from source

If you'd like to build Clipped yourself:

```bash
make generate  # Generate Xcode project via XcodeGen
make build     # Build the app
make run       # Build and launch
make test      # Run tests
make test-build-paths DEVELOPER_ID_TEAM= # Check paths without probing local signing identities
```

Requires Xcode 16+ and Swift 6. See [CLAUDE.md](CLAUDE.md) for project structure and architecture details.

Local launch and packaging preserve build paths containing spaces. They use
Debug and Release settings respectively and stop if the build or settings lookup
fails. Packaging validates and hashes a staged ZIP before replacing the previous
package, so failures preserve the last archive. `make test-build-paths` checks
these behaviors with temporary fixtures and
real archive tools, without building, signing, or launching Clipped.
