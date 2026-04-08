# Clipped

Native macOS clipboard manager. Swift 6 + SwiftUI, menu bar-only app.

## Build & test

```bash
make generate  # XcodeGen from project.yml
make build     # Debug build
make run       # Build + launch
make test      # Run unit tests
make clean     # Clean build artifacts
```

## Project structure

```
Clipped/
  project.yml              # XcodeGen spec (source of truth for Xcode project)
  Sources/
    App/ClippedApp.swift   # Entry point, MenuBarExtra setup
    Models/ClipboardItem.swift
    Services/
      ClipboardManager.swift    # Core clipboard polling + item management
      SettingsManager.swift     # UserDefaults + SMAppService wrapper
      HistoryStore.swift        # JSON persistence to ~/Library/Application Support/Clipped/
      HotkeyManager.swift      # Carbon global hotkey (Cmd+Shift+V)
      LinkMetadataFetcher.swift # Async URL title fetching
      MarkdownConverter.swift   # RTF -> Markdown
    Views/
      ClipboardPanelView.swift
      SettingsView.swift
      Components/
        ClipboardItemRow.swift
        SearchBar.swift
        ContentTypeFilterBar.swift
        OnboardingOverlay.swift
  Tests/
    ClipboardManagerTests.swift
  Resources/
    Info.plist
    Clipped.entitlements
```

## Key conventions

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All services are `@MainActor`
- `@Observable` macro (not `ObservableObject`)
- Environment-based DI via `.environment()` in SwiftUI
- No third-party dependencies
- App-sandboxed with network client entitlement (for link metadata fetching)

## Testing

Tests use the `Clipped` scheme (not a separate test scheme). The test target is `ClippedTests`.

## Deployment target

macOS 15.0 (Sequoia), Xcode 16+, Swift 6.
