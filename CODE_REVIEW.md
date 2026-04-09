# Code review — 2025-04-09

Cross-project audit comparing Clipped with Barred. Actions specific to Clipped are tracked below.

## Audit items

| Action | Status | Notes |
|---|---|---|
| Protocol-based DI for services | Done | `SettingsManaging`, `HistoryStoring`, `LinkMetadataFetching` protocols added. ClipboardManager accepts protocol types for all three dependencies. |
| Expand test files (1 per service) | Done | Split into 6 test suites across separate files. Added mock implementations for all three protocols. 39 tests (up from 20). |
| Standardize os.Logger | Done | All 7 services now have a `Logger` instance with subsystem `com.mcclowes.Clipped`. Log calls added at key state changes and error paths. |
| Align Makefile targets | Done | Added `help` target, added `release`/`package` to `.PHONY`. |
| Add CODE_REVIEW.md | Done | This file. |

## Architecture notes

- Services use `@Observable` + SwiftUI `.environment()` for DI at the view layer
- Protocol-based DI is used at the service layer (ClipboardManager depends on protocol types, not concrete singletons)
- Mocks in `Tests/Mocks.swift` implement all three protocols for isolated unit testing
- No third-party dependencies
