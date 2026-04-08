# Clippers

A lightweight, native macOS clipboard manager that fits the platform aesthetic and gets out of the way.

## Features

- **Clipboard history** — Tracks the last 10 clipboard entries with content type detection
- **Format preservation** — Rich text, URLs, images, and code snippets retain their formatting
- **Pinning** — Pin frequently used items so they persist above the history window
- **Search & filter** — Filter by content type or search by text
- **Secure mode** — Automatically skips clipboard entries from password managers
- **Global hotkey** — `⌘⇧V` to open the panel from anywhere

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16+
- Swift 6

## Building

```bash
cd Clippers
xcodegen generate
xcodebuild -project Clippers.xcodeproj -scheme Clippers -destination 'platform=macOS' build
```

## Testing

```bash
xcodebuild -project Clippers.xcodeproj -scheme ClippersTests -destination 'platform=macOS' test
```

## Architecture

Menu bar-only app (`LSUIElement`) using SwiftUI's `MenuBarExtra` with MVVM:

- `ClipboardManager` — `@Observable` service that polls `NSPasteboard` for changes
- `SettingsManager` — `@Observable` wrapper around `UserDefaults`
- `HotkeyManager` — Carbon-based global hotkey registration (`⌘⇧V`)
- SwiftUI views for the panel, item rows, search, and filtering
