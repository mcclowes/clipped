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

All Swift code lives under `Clipped/`. Run `find Clipped/Sources Clipped/Tests -name '*.swift'` for an
authoritative listing — do not hand-maintain a tree here (it rots). Notable services:

- `Sources/Services/ClipboardManager.swift` — orchestrator for ingestion, policy, history persistence scheduling
- `Sources/Services/PasteboardMonitor.swift` — polls `NSPasteboard.changeCount`
- `Sources/Services/ClipboardHistory.swift` — in-memory history + debounced save
- `Sources/Services/HistoryStore.swift` + `HistoryCrypto.swift` + `KeychainKeyStore.swift` — encrypted persistence
- `Sources/Services/LinkMetadataFetcher.swift` — `LPMetadataProvider` cache with SSRF filtering
- `Sources/Services/ScreenshotWatcher.swift` — dispatch-source watch on `~/Desktop` screenshots
- `Sources/Services/HotkeyManager.swift` — Carbon global hotkey
- `Sources/Services/AppPasteboardProfiles.swift` — per-app pasteboard type profiles (e.g. Logic Pro)
- `Sources/Services/OnboardingSeeder.swift` — first-launch example items

Resources: `Resources/Info.plist`, `Resources/Clipped.entitlements`, `Resources/Assets.xcassets/`.
Project spec: `Clipped/project.yml` (XcodeGen — source of truth).

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
