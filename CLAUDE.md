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
- `Sources/Services/Signposts.swift` — `OSSignposter` handles for performance instrumentation

Resources: `Resources/Info.plist`, `Resources/Clipped.entitlements`, `Resources/Assets.xcassets/`.
Project spec: `Clipped/project.yml` (XcodeGen — source of truth).

## Observability

Logging uses `os.Logger` (subsystem `com.mcclowes.clipped`, one category per service).

Performance is instrumented with `OSSignposter` via `Signposts.swift`. Attach Instruments
(the *os_signpost* / *Points of Interest* instrument) and filter on subsystem
`com.mcclowes.clipped` to see the clipboard pipeline. Signposts emitted:

| Category     | Name                     | Kind     | Source                              |
|--------------|--------------------------|----------|-------------------------------------|
| Clipboard    | `Ingest`                 | interval | `ClipboardManager.ingest(_:)`       |
| Clipboard    | `PasteboardChange`       | event    | `PasteboardMonitor.check()`         |
| History      | `SaveHistory`            | interval | `ClipboardHistory.saveHistory()`    |
| HistoryStore | `Save` / `Load`          | interval | `HistoryStore.save/load`            |
| HistoryStore | `CorruptedHistoryBackup` | event    | `HistoryStore.load()` recovery path |
| LinkMetadata | `FetchMetadata`          | interval | `LinkMetadataFetcher.fetchMetadata` |

Signposts are near-zero cost with no tracing tool attached, so they ship in release builds.

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

Test framework is **Swift Testing**, not XCTest. There are no `XCTest` imports anywhere in the suite — every test file uses:

```swift
@testable import Clipped
import Testing

@MainActor
struct FooTests {
    @Test("Sentence-case description of behaviour")
    func someBehavior() { #expect(...) }
}
```

Conventions when adding tests:

- Group tests in a `struct` (typically `@MainActor` when the system under test is `@MainActor`, which most services are).
- Use `@Test("…")` with a sentence-case description; the function name can be terse.
- Prefer `#expect` for assertions and `#require` (with `try`) to unwrap-or-fail.
- Reuse the test doubles in `Tests/Mocks.swift` rather than building new mocks per file.
- Tests that exercise wiring between multiple services live in `IntegrationTests.swift`; per-service unit tests live next to the service.

## Deployment target

macOS 15.0 (Sequoia), Xcode 16+, Swift 6.
