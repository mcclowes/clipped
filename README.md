# Clipped

A lightweight, native macOS clipboard manager that fits the platform aesthetic and gets out of the way.

## Features

- **Clipboard history** — Tracks clipboard entries with content type detection (configurable history size, default 10)
- **Format preservation** — Rich text, URLs, images, and code snippets retain their formatting
- **Pinning** — Pin frequently used items so they persist above the history window
- **Search & filter** — Filter by content type or search by text
- **Secure mode** — Automatically skips or auto-expires clipboard entries from password managers (configurable timeout)
- **Global hotkey** — `⌘⇧V` to open the panel from anywhere
- **Persistence** — Optionally persist clipboard history across app restarts
- **Launch at login** — Start Clipped automatically via `SMAppService`
- **Paste matching style** — Strip formatting and paste as plain text
- **Markdown conversion** — Convert rich text clipboard items to Markdown
- **Link previews** — Automatically fetches page titles for URL items
- **Export** — Merge and copy multiple clipboard items at once
- **Screenshot capture** — Automatically detects and captures new screenshots
- **Sticky notes** — Pin clipboard items as floating sticky notes on your desktop

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16+
- Swift 6

## Building

```bash
make generate  # Generate Xcode project from project.yml via XcodeGen
make build     # Build the app
make run       # Build and launch the app
```

Or manually:

```bash
cd Clipped
xcodegen generate
xcodebuild -project Clipped.xcodeproj -scheme Clipped -configuration Debug build
```

## Testing

```bash
make test
```

Or manually:

```bash
xcodebuild -project Clipped.xcodeproj -scheme Clipped -configuration Debug test
```

## Architecture

Menu bar-only app using SwiftUI's `MenuBarExtra` (no Dock icon, no app switcher entry):

- `ClipboardManager` — `@Observable` service that polls `NSPasteboard` for changes
- `SettingsManager` — `@Observable` wrapper around `UserDefaults` and `SMAppService`
- `HistoryStore` — JSON-based persistence to Application Support directory
- `HotkeyManager` — Carbon-based global hotkey registration (`⌘⇧V`)
- `LinkMetadataFetcher` — Async page title resolution for URL items
- `MarkdownConverter` — RTF-to-Markdown conversion
- `ScreenshotWatcher` — Monitors for new screenshots and adds them to clipboard history
- `StatusBarController` — NSPopover-based menu bar panel controller
- SwiftUI views for the panel, item rows, search, filtering, settings, sticky notes, and onboarding
