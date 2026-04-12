# Clipped — senior engineer code review

> Reviewer posture: principal engineer, new to this brownfield repo, intentionally critical. The goal is to help the team ship a more robust clipboard manager and grow as engineers — not to list every stylistic gripe. Where I'm harsh, the point is the reasoning, not the score.

## How to read this

Each finding has: **file / area**, the problem, why it matters, and a concrete direction. "P0" = ship-blocker / user-data or privacy risk, "P1" = real bug users will hit, "P2" = design smell that will rot over time.

Line numbers are approximate — the shape of the code is what matters.

---

## 1. Privacy & sensitive data — the most important section

A clipboard manager is, by definition, a system-wide recorder for whatever the user copies. Privacy bugs here aren't bugs, they're incidents. This is where I'd spend week one.

### 1.1 No SSRF guard in `LinkMetadataFetcher` — P0
**`Sources/Services/LinkMetadataFetcher.swift`**

The fetcher allows `http`/`https` but does not reject `localhost`, `127.0.0.0/8`, `::1`, link-local (`169.254/16`), RFC1918 ranges, or `.local` mDNS names. If a user copies a link to a homelab Grafana, a router admin page, or an internal company tool, Clipped will silently issue an outbound request to it. That leaks:

- Existence and responsiveness of internal services.
- Server banners, titles, and favicons into the persisted history cache.
- Triggers any side-effectful GET endpoint the user has on their network.

**Fix direction:** resolve the host, reject non-routable / private ranges before calling `LPMetadataProvider`. Document the policy. Add a test matrix.

### 1.2 "Sensitive" auto-removal is advisory, not enforced — P0
**`Sources/Services/ClipboardManager.swift` `scheduleSecureAutoRemoval`**

Secure auto-removal is a fire-and-forget `Task.sleep` then `pasteboard.clearContents()`. If the app crashes, is force-quit, logs out, or sleeps across the timer, the secret stays on the system pasteboard. The user thinks they're protected; they aren't.

Worse: the timeout is captured at scheduling time, so changing the setting at runtime doesn't shorten pending timers, and there's no persistence, so recovery across launches is impossible.

**Fix direction:** (a) persist pending secure-removals with their deadline and re-check on launch and on wake; (b) re-read the current timeout inside the loop; (c) register for `NSWorkspace.willSleepNotification` and either extend or clear immediately.

### 1.3 Password-manager items are read before being flagged — P1
By the time `isSensitive` is set, the plaintext is already a `String` in `ClipboardItem` and has flowed through mutation rules. Swift `String` doesn't zero its backing on deallocation, so we have:

1. Our in-memory copy.
2. Transient copies made during type-sniffing and mutation rules.
3. Whatever the OS pasteboard is still holding.

**Fix direction:** detect `org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType` / password-manager UTIs **before** reading the string data. If sensitive, record metadata only, never the content. Add a test.

### 1.4 Screenshots can contain secrets — P2
`ScreenshotWatcher` ingests every new screenshot. A user screenshotting a 2FA code, a password reset email, or a Slack DM is now persisted to encrypted history forever. That's arguably correct behavior, but the user hasn't consented to "every screenshot you take lives forever". At minimum this needs an explicit onboarding line and a per-source opt-out.

---

## 2. Concurrency — Swift 6 strict mode is lulling us into false confidence

Strict concurrency catches data races; it doesn't catch *semantic* bugs. Several patterns here are type-safe but still wrong.

### 2.1 Fire-and-forget `Task { [weak self] in … }` everywhere — P1
**`ClipboardManager.swift` (auto-removal, metadata fetch scheduling)**

These tasks swallow cancellation and errors. If `self` goes away mid-task, the side effect is dropped silently. If decryption or network throws, nobody notices. The pattern is:

```swift
Task { [weak self] in
    try? await Task.sleep(for: .seconds(timeout))
    self?.remove(item)
}
```

`try?` on `Task.sleep` means a **cancelled** sleep fires the removal immediately — the opposite of what you want on cancellation. Use `try await` and let cancellation propagate, or handle `CancellationError` explicitly.

### 2.2 Carbon hotkey callback routes through `HotkeyManager.shared` — P2
**`HotkeyManager.swift`**

The C callback hops to `Task { @MainActor in HotkeyManager.shared.fire(...) }`. `.shared` inside a C trampoline is a smell: the callback is bound to a global, not the instance that installed it. If we ever want per-window hotkeys, testability, or teardown-during-callback safety, this bites. Pass `self` as `userData` via `InstallEventHandler` and cast back with `Unmanaged.passUnretained`.

### 2.3 `ScreenshotWatcher` handler fix is still racy — P1
The recent crash fix (commit 712c525) wraps the handler body in `Task { @MainActor in }`. The handler still runs on a utility queue; at app shutdown the source may fire after `self` starts tearing down but before cancel completes. `[weak self]` helps, but the `Task` itself may outlive the source.

Also: 250 ms debounce is fixed. On a spinning disk or an SMB-mounted screenshots folder, `screencapture` may still be writing. `NSImage(contentsOf:)` will return a truncated image or nil, and we'll ingest garbage.

**Fix direction:** use `DispatchSource` cancellation semantics properly, and after the debounce fires, verify the file is stable (size unchanged across two reads) before ingesting.

### 2.4 Pasteboard polling has no coalescing — P2
A 0.5 s `Timer` polls `changeCount`. Many apps mutate the pasteboard multiple times per user action (e.g., copy rich text, then overwrite with plain text). We either miss intermediate states (fine) or occasionally race and capture the intermediate state (not fine). Document the invariant, add a test.

### 2.5 `@MainActor` on everything defeats the purpose of actors — P1
If every service is main-actor, you don't actually have concurrency — you have a single-threaded app with async sugar. That's fine for UI state but wrong for `LinkMetadataFetcher`, `HistoryStore` I/O, crypto, and image decoding. Right now we're doing AES-GCM on the main thread at load time. Push I/O and crypto off main and hop on only to publish results.

---

## 3. Persistence & crypto

### 3.1 Decrypt failures are swallowed with `try?` — P1
**`HistoryStore.swift` (`loadEncryptedImageFile`, legacy migration)**

`try? crypto.decrypt(...)` → nil. The user sees items load with missing images and no explanation. If the key is actually wrong (Keychain evicted, iCloud sync mid-restore), we'll quietly throw away the entire history over time as new writes use a different key.

**Fix direction:** distinguish "corruption" from "wrong key". On a systematic decrypt failure (e.g. >3 items in one load pass), surface an alert and refuse to overwrite. Log via unified logging with a stable subsystem.

### 3.2 No versioning on the encrypted envelope — P1
If we later change the AEAD scheme (AES-GCM → ChaCha20-Poly1305, add a KDF, add associated data), there's no version byte to detect. Add a 1-byte `version` prefix now, before users accumulate history you can't migrate.

### 3.3 Keychain key loss is unrecoverable and undetected — P1
If the Keychain entry is evicted (new Mac, password reset, Keychain corruption), `KeychainKeyStore` generates a fresh key and every prior encrypted file silently fails to decrypt. We re-encrypt new items under the new key, making the history look partially empty.

**Fix direction:** store a known plaintext canary encrypted under the key. On launch, attempt canary decrypt; if it fails, show "history is locked — the encryption key could not be found" — don't silently discard.

### 3.4 `writeAtomically` doesn't fsync — P2
`replaceItemAt` gives atomic rename on APFS but not durability across power loss. Fine for a clipboard manager; worth a comment so the next engineer doesn't assume stronger guarantees.

### 3.5 Orphan-image sweep is O(N) on every save — P2
Full directory scan on every mutation. At 10k historical images this is noticeable. Use reference-counting or a periodic sweep gated by a `last-swept` timestamp.

---

## 4. Pasteboard correctness

### 4.1 Custom types must be re-applied in their original order — P1
**`PasteboardMonitor` snapshot/replay**

Snapshotting types via a `Set` loses declaration order. Some apps (Logic Pro region paste is the exact example the team just fixed in commit a0125d5) care which type is offered *first*. The fix preserves types but needs a regression test that asserts order round-trips — I don't see one.

### 4.2 Per-type size cap missing — P2
Total cap is 2 MB. A malicious or buggy app could stuff one type with 1.99 MB of noise and starve the real types. Cap per-type and total.

### 4.3 SVG sniff bounded at 2048 bytes — P2
Large SVGs with comments or DOCTYPE preamble beyond 2 KB aren't detected. Either sniff more, or trust the UTI (`public.svg-image`).

### 4.4 Paste simulation has no success verification — P2
We send Cmd+V and hope. If Accessibility permission is missing or the target app swallows the event, the user sees nothing. Detect permission up front and tell them.

### 4.5 `isSensitive` items can still round-trip through copy-to-clipboard — P1
Copy-out doesn't reschedule an auto-removal; only ingestion does. See 1.2.

---

## 5. Link metadata fetching

### 5.1 No timeout on image/icon fetch — P1
`LPMetadataProvider.timeout = 5` doesn't propagate to `NSItemProvider.loadDataRepresentation`. A slow favicon stalls the task indefinitely. Wrap with a `Task.select`-style race or an explicit deadline.

### 5.2 Per-icon size limit doesn't bound aggregate — P2
500 KB each, two providers, N URLs → unbounded cache growth. Cap total cache size.

### 5.3 In-flight Task map leaks cancelled entries — P2
Cancelled Tasks remain in `inFlight[url]`. Always remove entries in `defer { inFlight[url] = nil }`, regardless of outcome.

---

## 6. UI / SwiftUI

### 6.1 `displayedItems` recomputed per render — P2
Filters + search run on every body evaluation in `HistoryWindowView` and `ClipboardPanelView`. Memoize with `@State` + `.onChange(of:)` or move to a derived computed on the store with caching.

### 6.2 No hard cap on pinned items — P2
A user pinning hundreds of items will drag `List` performance. Either cap at (say) 50 with a clear message, or lazy-load the pinned section.

### 6.3 Images held full-resolution in memory — P1
`ClipboardItem` keeps the full image. A clipboard capturing 4K screenshots at 50 items = ~1.5 GB resident. Need thumbnails in memory, full data on disk, lazy load on detail view.

---

## 7. Settings

### 7.1 `didSet` writes to UserDefaults synchronously — P2
Rapid mutation thrashes UserDefaults. Coalesce with a debounced writer.

### 7.2 SMAppService error UX is a silent toggle revert — P1
If `register()` throws (user denied, sandboxed issue), the toggle snaps back with no alert. Show the error. This is exactly the kind of bug that makes users think "this app is buggy" when the OS refused.

### 7.3 Mutation-rules JSON has no schema version — P1
When rule shape changes across app versions, old entries decode partially or not at all. Version the container.

---

## 8. Testing gaps

- No test proving pasteboard type **order** is preserved (the exact bug the team just fixed).
- No tests for `LinkMetadataFetcher` timeout, SSRF, or in-flight dedup cleanup.
- No tests for decrypt-failure behavior; need a golden file with the *wrong* key and an assertion that we don't nuke data.
- No test for "app terminated mid secure-removal" — we don't even have the recovery code to test yet (see 1.2).
- No integration test for `ScreenshotWatcher` with a partially-written file.
- `Mocks.swift` `MockPasteboard` reorders types freely; diverges from real `NSPasteboard` behavior and will hide order bugs.

---

## 9. Project hygiene

### 9.1 `CLAUDE.md` is already stale
It documents paths like `Sources/Services/...`, but actual layout is `Clipped/Sources/Services/...`. It references files that no longer exist (`OnboardingOverlay.swift` → now `OnboardingView.swift`) and omits files that do (`KeychainKeyStore.swift`, `AppPasteboardProfiles.swift`, `HistoryCrypto.swift`, `ClipboardHistory.swift`, `OnboardingSeeder.swift`). Docs that lie are worse than no docs — they mislead every new contributor and every agent. Either regenerate the file-tree section from a script, or delete it.

### 9.2 "Sandbox disabled" needs a `SECURITY.md` rationale
This is defensible for a clipboard manager (pasteboard works under sandbox, but Carbon hotkeys and some Accessibility features don't). Write it down so a future maintainer doesn't flip it on and break everything, and so reviewers have an answer before they ask.

### 9.3 Unified logging is ad hoc
`print` and `os_log` usage is scattered. Define one `Logger(subsystem: "app.clipped", category: …)` per service. Users can help you debug themselves.

---

## 10. Architectural smells

1. **`ClipboardManager` is a god object.** Polling, persistence scheduling, sensitive-data policy, paste simulation, onboarding seeding — all one type. Split along the seams: `Ingestion`, `Policy`, `Output`.
2. **Singletons used as DI shortcuts.** `HotkeyManager.shared`, `SettingsManager` accessed ambiently. Makes tests brittle. Pass instances via environment.
3. **App-specific profile logic (Logic Pro) lives inside the generic monitor.** Either introduce a `PasteboardProfile` protocol with registered handlers, or wall the special cases behind a single boundary.
4. **Mutation rules as persisted JSON inside UserDefaults.** UserDefaults is for settings, not user content. Move to a proper file.

---

## Prioritized punch list (if you only do five things)

1. **Add SSRF protection to `LinkMetadataFetcher`** (1.1). Easiest big-win privacy fix.
2. **Make secure-auto-removal crash-safe** (1.2). Persist pending removals, re-check on launch and wake.
3. **Version the crypto envelope and add a canary** (3.2, 3.3) **before** more users accumulate history you can't migrate.
4. **Distinguish decrypt-wrong-key from decrypt-corruption** (3.1). Stop silently dropping data.
5. **Regression-test pasteboard type order** (4.1). Don't re-break the Logic Pro fix.

---

## Notes for the team on *how to be a better engineer*

Independent of the specific bugs, these are patterns worth internalizing:

- **`try?` is a code smell 80% of the time.** It means "I don't want to think about this failure". In a clipboard manager, every `try?` is a potential way to lose user data silently. Use `do/catch`, log, and degrade explicitly.
- **Fire-and-forget `Task {}` is almost never what you want.** If the task matters, own its lifetime (store the handle, cancel on teardown). If it doesn't, ask why you're doing the work at all.
- **Security-sensitive code deserves explicit *allowlists*, not denylists.** "Scheme is http/https" is a denylist of everything else; the right check is "host is a public routable address". Same mindset for sensitive-type detection.
- **`@MainActor` on everything isn't concurrency — it's the opposite.** Put I/O, crypto, and network off-main and hop on only to publish results.
- **Silent fallbacks hide incidents.** Every `?? default`, `try? … ?? nil`, and empty-catch is a place where user expectation and app behavior diverge without telling anyone. Loud failure in development, graceful-but-logged failure in production.
- **Test the regression you just fixed, not the feature you just shipped.** The custom-pasteboard-type fix and the ScreenshotWatcher crash fix both lack direct regression tests. A fix without a test is a fix on probation.
- **Docs that lie are worse than no docs.** Fix `CLAUDE.md` or delete the file-tree section.
