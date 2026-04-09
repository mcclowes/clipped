# Clipped

Native macOS clipboard manager. Swift 6 + SwiftUI, menu bar-only app.

## Build & test

```bash
make generate  # XcodeGen from project.yml
make build     # Debug build
make run       # Build + launch
make test      # Run unit tests
make release   # Release build
make package   # Release build + zip for distribution
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
      ScreenshotWatcher.swift   # Monitors for new screenshots
      StatusBarController.swift # NSPopover-based menu bar controller
    Views/
      ClipboardPanelView.swift
      SettingsView.swift
      StickyNoteView.swift
      Components/
        ClipboardItemRow.swift
        SearchBar.swift
        ContentTypeFilterBar.swift
        FloatingPanelModifier.swift
        OnboardingOverlay.swift
  Tests/
    ClipboardManagerTests.swift
    HexColorParserTests.swift
    HistoryStoreTests.swift
    LinkMetadataFetcherTests.swift
    MarkdownConverterTests.swift
    SettingsManagerTests.swift
    Mocks.swift
  Resources/
    Info.plist
    Clipped.entitlements
    Assets.xcassets/         # App icon
```

## Pre-PR checklist

Always run these before committing or opening a pull request:

```bash
make lint      # SwiftFormat + SwiftLint — must pass with zero violations
make build     # Debug build must succeed
make test      # All unit tests must pass
```

If `make lint` fails, run `make format` to auto-fix SwiftFormat issues, then re-check with `make lint` (SwiftLint issues must be fixed manually).

Key lint rules to watch:
- **Max line width is 120 characters** (`.swiftformat` `--maxwidth 120`)
- **Hoist pattern `let`**: use `case let .foo(bar)` not `case .foo(let bar)`
- **Wrap long argument lists** `before-first` with balanced closing paren
- **`force_try` / `force_unwrapping`** are warnings — use `swiftlint:disable:next` only where justified (e.g. compile-time-constant regexes)

## Key conventions

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- All services are `@MainActor`
- `@Observable` macro (not `ObservableObject`)
- Environment-based DI via `.environment()` in SwiftUI
- No third-party dependencies
- App sandbox disabled; entitlements include network client, user-selected read-only files, app-scope bookmarks

## Testing

Tests use the `Clipped` scheme (not a separate test scheme). The test target is `ClippedTests`.

## Deployment target

macOS 15.0 (Sequoia), Xcode 16+, Swift 6.
