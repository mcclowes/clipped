# Clipped — code review

Last reviewed: 2026-04-09

---

## Previously resolved

Items from prior cross-project audit:

- Protocol-based DI added (`SettingsManaging`, `HistoryStoring`, `LinkMetadataFetching`). `ClipboardManager` accepts protocol types via constructor injection.
- Test coverage expanded to 39+ tests across 7 files with mock implementations in `Tests/Mocks.swift`
- os.Logger standardized across all 7 services (subsystem `com.mcclowes.Clipped`)
- Makefile aligned with `help`, `release`, `package` targets added
- CODE_REVIEW.md created (this file)
- Accessibility `.help()` labels added to all icon-only buttons (settings gear, reveal eye, ellipsis menu)
- Hardcoded hotkey string in onboarding fixed — now reads from `HotkeyManager.displayString`
- CLAUDE.md test section updated to list all 7 test files
- Logger subsystem standardized to lowercase `com.mcclowes.clipped` across all services
- Panel dimensions extracted to `StatusBarController.panelWidth/panelHeight` constants
- `ScreenshotWatcher` image extensions extracted to constant set, added `.heic` support

---

## Open items

### Medium priority

#### 4. `ClipboardManager` and `ScreenshotWatcher` lack protocol abstractions

`ClipboardManager` accepts protocols for its 3 dependencies — good. But `ClipboardManager` itself, `HotkeyManager`, `ScreenshotWatcher`, and `StatusBarController` have no protocol boundaries. Views depend on concrete types via `@Environment`.

**Impact:** These services can't be mocked for view testing or SwiftUI previews. Lower priority than the service-layer DI (which is done), but worth adding incrementally.

#### 5. No integration tests for multi-service workflows

Individual service tests are solid. But there's no test for the full flow: clipboard change → ClipboardManager detects → HistoryStore persists → reload preserves. A single integration test covering this path would catch wiring bugs.

### Low priority

#### 9. `ClipboardItemRow` is complex — consider extraction

This component handles image previews, sensitive masking, dual context menus (SwiftUI + NSMenu), hex colour parsing, hover states, and link titles. Consider splitting into smaller focused components.

#### 10. Carbon API for global hotkey

`HotkeyManager` uses the Carbon Event Manager — the oldest Apple API still in use. There's no modern replacement for global hotkeys outside accessibility APIs, so this is pragmatic. But document this as a known legacy dependency.

#### 11. `LinkMetadataFetcher` HTML title parsing is fragile

Simple regex-based `<title>` extraction. Will miss titles set via JavaScript, malformed HTML, or encoded entities beyond basic cases. Pragmatic for a clipboard manager, but document the limitation.

---

## Testing status

39+ tests across 7 files. Coverage is solid for core service logic:

| Area | Coverage | Notes |
|------|----------|-------|
| ClipboardManager (filtering, pinning, types) | Good | 13 tests |
| HistoryStore (persistence, corruption, security) | Good | 8 tests |
| SettingsManager (defaults, protocol) | Basic | 3 tests |
| LinkMetadataFetcher (parsing, caching) | Good | 3 tests |
| HexColorParser | Good | 6 tests |
| MarkdownConverter | Good | 8 tests |
| Multi-service integration | Missing | No end-to-end workflow tests |
| View rendering / interaction | Missing | No UI tests |
| HotkeyManager | Missing | Difficult to test (Carbon) |
| ScreenshotWatcher | Missing | Requires filesystem setup |
| StatusBarController | Missing | Requires NSApplication context |

---

## Cross-project alignment with Barred

| Item | Status |
|------|--------|
| Protocol-based DI (service layer) | Done |
| SwiftFormat + SwiftLint | Done |
| os.Logger on all services | Done |
| Makefile `generate` target | Done (Barred to rename `xcode` → `generate`) |
| Logger subsystem casing | Done (`com.mcclowes.clipped`) |
| `.swiftlint.yml` rule alignment | Review and align with Barred |
| CI macOS version pinned | Done (`macos-15`) |

## Architecture notes

- Services use `@Observable` + SwiftUI `.environment()` for DI at the view layer
- Protocol-based DI is used at the service layer (ClipboardManager depends on protocol types, not concrete singletons)
- Mocks in `Tests/Mocks.swift` implement all three protocols for isolated unit testing
- No third-party dependencies
- Swift 6 strict concurrency with `@MainActor` on all services
