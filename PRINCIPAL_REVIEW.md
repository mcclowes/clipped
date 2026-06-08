# Clipped — principal engineer code review

**Reviewer stance:** onboarding principal engineer, deliberately critical. The goal is not to be mean for its own sake — it's to find the things that will bite you in production and to use each one as a teaching moment. Read the "why this matters" notes; they're the point.

**Scope:** full holistic pass. ~11k lines, Swift 6 strict concurrency, SwiftUI, menu-bar app. I read the security/persistence/concurrency core line by line and used focused sub-reviews for the view layer, the test suite, and the peripheral services.

**Overall verdict:** this is *good* code with genuinely thoughtful touches — encrypted-at-rest history, SSRF awareness, nspasteboard.org conventions, signpost instrumentation, a real DI seam for tests. It is well above the median macOS side-project. That's exactly why it's worth reviewing hard: the remaining problems are the subtle ones, and the team is clearly capable of fixing them. The headline issues are (1) the SSRF filter has real bypasses, (2) there is a silent data-loss-on-quit bug, (3) the password-manager skip list is out of date and inconsistent with the rest of the app, and (4) the clipboard ingest path runs ~20 regex scans synchronously on the main actor with no size cap.

---

## Table of contents

1. [Security](#1-security)
2. [Correctness bugs & unspotted edge cases](#2-correctness-bugs--unspotted-edge-cases)
3. [Concurrency](#3-concurrency)
4. [Performance](#4-performance)
5. [Architecture & code organization](#5-architecture--code-organization)
6. [The view layer](#6-the-view-layer)
7. [Testing](#7-testing)
8. [What's genuinely good](#8-whats-genuinely-good)
9. [Prioritized action plan](#9-prioritized-action-plan)
10. [Teaching notes for the team](#10-teaching-notes-for-the-team)

---

## 1. Security

This app reads everything you copy, persists it to disk, and reaches out to the network on your behalf. The security bar is therefore high. The team clearly knows this — there's encryption, an SSRF filter, and password-manager handling. The problem is that all three have gaps.

### 1.1 [HIGH] The SSRF filter is bypassable — it inspects the URL string, not the resolved address

`LinkMetadataFetcher.isFetchableURL` (`LinkMetadataFetcher.swift:65-81`) is the only thing standing between "user copied a URL" and "app issues an HTTP GET to an arbitrary host." It runs automatically whenever a URL is copied and `fetchLinkPreviews` is on (default `true`). That makes it an *auto-triggered* SSRF surface: the victim merely has to copy a link.

The filter checks IP **literals** only. It does not resolve hostnames. Concrete bypasses:

- **DNS rebinding / hostname pointing at a private IP.** `http://internal.attacker.com/` passes every check in `isFetchableURL` (valid scheme, has a dot, not an IP literal), and then `LPMetadataProvider` resolves the name itself — to `127.0.0.1`, `169.254.169.254` (cloud metadata), or any internal host. The IP checks never run because the host isn't an IP literal.
- **Non-dotted-decimal IP encodings.** `ParsedIPv4` (`LinkMetadataFetcher.swift:191-200`) only accepts exactly four dotted octets parsed with `UInt8(part)`. So `http://2130706433/` (decimal for 127.0.0.1), `http://0x7f000001/`, and `http://127.1/` (valid shorthand for 127.0.0.1) all fail to parse as IPv4, fall through to the "is it a hostname?" branch, and `127.1` even passes `!host.contains(".")`… actually `127.1` *does* contain a dot, so it passes and is fetched. The OS resolver expands all of these to loopback.
- **IPv4-mapped IPv6.** `http://[::ffff:127.0.0.1]/` — `ParsedIPv6.isPrivateOrReserved` (`LinkMetadataFetcher.swift:225-231`) checks `== "::1"`, `hasPrefix("fe80"/"fc"/"fd"/"ff")`. An IPv4-mapped address starts with `::ffff:`, matches none of those, and is fetched straight to loopback.

**Why this matters:** internal port scanning, hitting cloud metadata endpoints, and triggering state-changing GET endpoints on the user's LAN — all from a copied link. The current filter creates a *false sense of safety*: the code looks hardened, so the next engineer assumes it is.

**Fix direction:** you cannot make this airtight with string parsing because the resolver runs after your check. The robust options are (a) resolve the host yourself, validate *every* resolved A/AAAA record against the deny-list, and only then fetch (still racy against rebinding, but far better), or (b) treat link previews as opt-in and document the residual risk, or (c) route the fetch through a vetting proxy. At minimum, fix the literal-parsing bypasses (octal/decimal/hex/shorthand IPv4, IPv4-mapped IPv6) and add the cloud-metadata IPs (`169.254.169.254`, `fd00:ec2::254`) explicitly. Add a test matrix of bypass strings — this is exactly the kind of logic that rots silently.

### 1.2 [HIGH] Password-manager skip list is stale and inconsistent with the rest of the app

`ClipboardManager.swift:7-13` is the security-critical set of bundle IDs whose clipboard output is force-marked sensitive and never persisted. It lists 1Password **6/7** (`com.agilebits.onepassword7`, `com.agilebits.onepassword-osx`), LastPass, Bitwarden, KeePassXC. It does **not** list 1Password **8**, whose bundle ID is `com.1password.1password` — and the app *already knows that ID*: it's hardcoded in `ClipboardItemRow.swift:247` for a UI affordance.

So the single most popular password manager's current version is recognized for a context-menu button but not for the persistence guard. It happens to still work *only* because 1Password sets the `org.nspasteboard.ConcealedType` flag (caught by the `hasConcealed` path). You are one vendor behavior change away from silently writing passwords to disk. Dashlane, Proton Pass, Enpass, and Keeper aren't covered at all.

**Why this matters:** "it works because of a second, independent mechanism" is not a guarantee — it's luck. And the inconsistency (`com.1password.1password` known in one file, absent in the other) is the tell that nobody has a single source of truth for "what is a password manager."

**Fix direction:** one shared, tested constant for password-manager bundle IDs, referenced by both sites. Add 1Password 8 and the other major managers. Add a test that asserts the row's ID and the skip-list overlap.

### 1.3 [MEDIUM] Secure auto-removal can miss a pinned item

`scheduleSecureAutoRemoval` (`ClipboardManager.swift:247-260`) removes only from `history.items`. If a password-manager item is ingested with a timeout and the user pins it before the timer fires, `togglePin` moves it into `pinnedItems` (`ClipboardHistory.swift:86-98`), and the removal's `history.items.removeAll { $0.id == itemID }` no longer finds it. The secret then lives indefinitely (in memory; it still won't persist because `isSensitive` blocks that). Remove by ID from both arrays.

### 1.4 [LOW–MEDIUM] Crypto and persistence: small but real notes

- **Crypto design is sound.** `ChaChaPoly` combined format (`HistoryCrypto.swift`), 256-bit key in the login Keychain with `WhenUnlockedThisDeviceOnly`, key never on disk, `0o600` temp files, atomic `replaceItemAt`. This is the right shape. Credit where due.
- **`StoredEntry` is hand-duplicated three times** (`HistoryStore.swift:339-419`): the memberwise `init`, `strippingImageData()`, and `withImageData()` each list all 18 fields. Add a field and forget one of the two copy helpers and you get **silent data loss on round-trip** with no compiler error. This is a correctness landmine wearing a serialization costume. Make `imageData` a `var` and mutate a copy, or derive the wire form differently — anything that removes the three-places-to-edit hazard.
- **Plaintext-corruption recovery moves `history.enc` aside but loses the side-car images** (`HistoryStore.swift:171-180`): on JSON-decode failure you back up `history.enc` and return empty, but the `images/*.enc` blobs are now orphaned and will be swept on the next save. Probably fine (the history that referenced them is gone), but worth a comment so the next reader doesn't think it's a leak.

---

## 2. Correctness bugs & unspotted edge cases

This is the section the brief asked for most directly: what hasn't been spotted.

### 2.1 [HIGH] Data loss on quit — the debounced save is never flushed

`saveHistory` debounces 250ms (`ClipboardHistory.swift:184-203`). `flushPendingSaves()` exists (`:206-210`) and the comment says it's "intended for tests and app shutdown" — but **nothing calls it on shutdown.** Both quit paths are bare `NSApplication.shared.terminate(nil)` (`ClipboardPanelView.swift:119,368`), and there is no `applicationWillTerminate`/`applicationShouldTerminate` flush anywhere (confirmed by grep).

**Repro:** copy something, immediately ⌘Q (or hit Quit in the panel) within 250ms. The final copy never reaches disk.

**Why this matters:** silent data loss is the worst kind of bug — no crash, no log, just a missing item that the user swears they copied. The infrastructure to prevent it already exists and is wired up to nothing.

**Fix direction:** implement `applicationShouldTerminate` → kick off `flushPendingSaves()` → `.terminateLater` / `replyToApplicationShouldTerminate(true)`. This is the canonical AppKit pattern for "let me finish writing before you kill me."

### 2.2 [HIGH] No size cap on ingested clipboard content

`PasteboardMonitor.readClipboardItem` and `ClipboardManager.ingest` impose **no upper bound** on text or image size (grep confirms the only size logic is PNG magic-byte sniffing). Copy a 200 MB log file or a giant image and the app: holds it in memory, runs ~20 regex scans over it (see §2.3), base64-adjacent re-encodes it for persistence, and keeps it in history. `ScreenshotWatcher.ingestScreenshot` (`ScreenshotWatcher.swift:170-174`) has the same unbounded `Data(contentsOf:)`.

The custom-pasteboard-types path *does* cap at 2 MB (`PasteboardMonitor.swift:238`), which proves the team knows this matters — it just wasn't applied to the primary text/image path.

**Fix direction:** a configurable max ingest size (text length and image bytes), enforced before detection and before persistence. Decline or truncate above it.

### 2.3 [HIGH] ~20 regex passes run synchronously on the main actor for every copy

Every plain-text copy, on the main actor, runs: `DeveloperContentDetector` (5 patterns + JSON check, `ClipboardItem.swift:469-487`), `ContentCategoryDetector` (6 sub-detectors, several multi-pattern, `:281-290`), then in `ingest` `SecretDetector` (10 patterns, `:429-433`), plus the mutation pipeline's `DetectCodeSnippetMutation` (up to 8 more regexes per the service review). That's north of twenty full-string regex scans, serialized on the UI actor, with no size guard (see §2.2).

For normal short clips this is invisible. For a multi-megabyte paste it is a visible main-thread hang — the menu bar stops responding while you scan a novel for hex colors. The detectors are pure and stateless; they're ideal candidates to run off-actor (or at least to gate behind a size cap and short-circuit).

### 2.4 [MEDIUM] Index-based selection over a mutable list copies the wrong item

The panel tracks selection as an `Int` (`ClipboardPanelView.swift`, `selectedIndex`) and only resets it when `searchQuery` changes. Pin/unpin/delete from the context menu reorders the visible list without resetting the index, so the next ⌘-paste/Return copies whatever now sits at that index. Selection over a reorderable collection must be keyed by identity (`ClipboardItem.ID`), not position. This is both a correctness bug and the root cause of the O(n²) `indexOf` perf issue in §4.

### 2.5 [MEDIUM] KeyRecorder leaks a global key monitor that swallows all keystrokes

`KeyRecorderView` installs an `NSEvent` local monitor when recording (`KeyRecorderView.swift:44-58`) and has **no `onDisappear`** to remove it. Close Settings (or navigate away from the onboarding step that embeds it, `OnboardingView.swift:125`) mid-recording and the monitor stays installed, returning `nil` for every keyDown app-wide — i.e. the app eats your keyboard until relaunch. User-facing, app-breaking, one-line fix.

### 2.6 [MEDIUM] `FloatingPanelModifier` can silently fail to apply the screen-sharing privacy setting

`FloatingPanelModifier.swift:16-41` configures the window inside a `DispatchQueue.main.async` from `makeNSView`, when `view.window` is still `nil`, and *hopes* the window exists one runloop tick later. If attachment is slower (it sometimes is for freshly-created `Window` scenes), none of the floating/level/`sharingType` config applies — including `hideFromScreenSharing`, which is a *privacy* feature (`SettingsView.swift:153`). A privacy guarantee that can silently no-op is worse than none. Observe `viewDidMoveToWindow` instead of guessing with GCD.

### 2.7 [LOW] A scattering of smaller edge cases worth a ticket each

- **`StickyNoteView` auto-dismiss misses the initial-nil case** (`StickyNoteView.swift:37-41`): `onChange(of: item == nil)` only fires on a transition, so an already-gone item leaves the window on the fallback screen rather than auto-closing.
- **Two uncoordinated first-launch flags**: `OnboardingSeeder`'s `hasSeededOnboardingExamples` vs `ClippedApp`'s `hasLaunchedBefore`. Reset one and they desync — onboarding without seeds, or vice versa.
- **`maxHistorySize` / hotkey key codes use `> 0` as "is it set?"** (`SettingsManager.swift:204-205,250-260`): key code `0` is a real key (`kVK_ANSI_A`), so a user who binds to 'A' silently loses it on next launch. Use `object(forKey:) == nil` like the booleans do.
- **`StripTrackingParamsMutation` strips `ref`** (`ClipboardMutationService.swift:219`): `ref` is a legitimate, load-bearing query param on GitHub, OAuth flows, and others. Stripping it silently breaks links.
- **`AppPasteboardProfiles.extractTrackName` drops leading numeric tokens** (`AppPasteboardProfiles.swift:49-64`): a Logic track named "808 Kick" becomes "Kick".
- **`HistoryStore` writes to the user's real `~/Library/Application Support/Clipped` even in tests** (`HistoryStore.swift:56`, hard-coded) — so the suite can corrupt the running app's history (see §7).

---

## 3. Concurrency

Strict concurrency is on and the `@MainActor`-everywhere + actor-for-IO split is the right call. No data races spotted. The notes are about robustness, not safety.

- **Polling design is a reasonable, well-commented tradeoff** (`PasteboardMonitor.swift:60-64`). There's no pasteboard-change notification API, so a 0.5s timer is standard. Accept it — but document the consequence: two *different* copies within 500ms collapse to one observed change, and the intermediate is lost forever. That's a product decision, not a bug, but it should be a known one.
- **Observation re-arm in `ClippedApp.observeScreenSharingPolicy`** (`ClippedApp.swift:100-110`): `withObservationTracking` fires once and re-subscribes inside a `Task` hop, leaving a window where a change can be missed. Rapid toggles can leave a window in the wrong sharing state. A `didSet` on the setting is more robust than the observe-then-re-observe dance.
- **`scheduleSecureAutoRemoval` and the link-metadata write-back are untestable by construction** because they call `Task.sleep(for:)` against the real clock directly. Inject a clock (`any Clock`) so the fire-and-cancel branches become deterministic. Right now the most security-sensitive timing path in the app has no test that proves removal actually happens.
- **`HotkeyManager` fires each keypress through a fresh `Task { @MainActor }`** from the C callback (`HotkeyManager.swift:136-138`). For a toggle, two fast presses can interleave as open-then-immediately-close depending on scheduling. Minor, but it's the kind of nondeterminism that produces "sometimes the panel doesn't open" bug reports.

---

## 4. Performance

The view layer recomputes far more than it needs to. None of this is fatal at 50 items, but it's the difference between buttery and janky, and it compounds.

- **Filtered collections re-filter on every access.** `filteredItems`/`filteredPinnedItems` (`ClipboardHistory.swift:33-39,53`) allocate and filter a fresh array each call, and the panel body reads them a dozen-plus times per pass; `HistoryWindowView.items(for:)` re-concatenates `pinned + items` for every sidebar count (6×) and every toolbar read. Cache the filtered result and invalidate on change.
- **O(n²) selection math.** `indexOf` is called once per visible row and does a `firstIndex` over the concatenated visible list (`ClipboardPanelView.swift:185,449`). Fix §2.4 (id-based selection) and this disappears.
- **Images decode on every row body.** `NSImage(data:)` is called fresh per render in `HistoryWindowView`, `ClipboardItemRow`, and `StickyNoteView`, with no thumbnail/downsampling — full-resolution screenshots re-decoded during scroll. Pre-decode a cached, downsampled thumbnail keyed by item id (ImageIO `kCGImageSourceThumbnailMaxPixelSize`).
- **`RelativeDateTimeFormatter` allocated per row body** (`HistoryWindowView.swift:756-760`). The comment rationalizes it as cheap; it isn't. It's `@MainActor`-isolated code, so a single static instance is safe — the Sendable worry in the comment doesn't apply. Cache it.
- **Launch Services lookups uncached in some places, cached in others** (`ClipboardItemRow.is1PasswordInstalled` as `static var`, `SettingsView.AppIconView` per-body) while `HistoryWindowView.AppIconResolver` caches correctly. Pick the cached pattern everywhere.
- **`trimToMaxSize` is O(n²) on bulk overflow** (`ClipboardHistory.swift:149-156`): a `while` loop that re-scans for `count` and `lastIndex` each iteration. Fine for single-item overflow; quadratic on a large restore. One filtered pass would do it.

---

## 5. Architecture & code organization

The recent decomposition work (splitting `StatusBarController` into presenters, narrowing `ClipboardManager` from a "400-line god object") is the right instinct and visibly improved things. Two problems remain: the split didn't reach the biggest files, and one file is doing the opposite of single-responsibility.

### 5.1 `ClipboardItem.swift` is a 683-line grab-bag of ~16 types

The file named after the model contains: `ContentType`, `ContentCategory`, `SourceAppCategory`, `ClipboardFilter`, `ContentCategoryDetector`, `IPAddressDetector`, `MACAddressDetector`, `EmailDetector`, `PhoneNumberDetector`, `NumberDetector`, `SecretDetector`, `DeveloperContentDetector`, `ClipboardItem`, `ClipboardContent`, `SVGDetector`, and `HexColorParser`.

Through the **AI-readability lens** this is the worst offender in the codebase. Each detector is a pure, stateless, self-contained unit — the textbook case for its own file. An agent (or a new hire) asked to "tighten the secret-detection patterns" will never think to open `ClipboardItem.swift`, and once there, will burn context reading fifteen unrelated types. The "can this be understood in isolation?" test says *yes* for every detector — so they should each be isolated. Suggested layout: `Models/` keeps `ClipboardItem`, `ClipboardContent`, `ContentType`, `ContentCategory`, `SourceAppCategory`, `ClipboardFilter`; a new `Detection/` folder holds one file per detector.

### 5.2 The two largest view files still mix concerns

`HistoryWindowView.swift` (760 lines) bundles five view types plus `HistoryCategory`, `SourceAppGroup`, and `AppIconResolver` (model/util that doesn't belong under `Views/` at all). `ClipboardPanelView.swift` (507 lines) owns the quick menu, main panel, search wiring, keyboard nav, selection math, a clear/undo debounce, a toast system, and a custom `ButtonStyle`. These are exactly the kind of files the `StatusBarController` split was meant to prevent; finish the job for them too. `SummaryPopover.swift` is the model to copy — small, single-purpose, `Equatable` state, no `AnyView`.

### 5.3 Layering leaks

- A model conformance (`extension ContentType: Equatable {}`) is declared in a *view* file (`ContentTypeFilterBar.swift:39`). Put conformances with the type.
- Three presenters each declare a `static let logger` that is never used (`HistoryWindowPresenter`, `SettingsWindowPresenter`, `OnboardingWindowPresenter`) — dead code, and a missed chance at the window-lifecycle diagnostics the rest of the app instruments heavily.
- `HistoryWindowPresenter` and `SettingsWindowPresenter` retain their windows after close (`isReleasedWhenClosed = false`, no nil-out), while `OnboardingWindowPresenter` *does* nil out. Inconsistent, and the first two leak an entire SwiftUI hosting tree (with clipboard content) per app lifetime.

---

## 6. The view layer

Detailed findings live in §2 and §4; the systemic theme is **accessibility is incomplete**, and it's incomplete in a consistent way that suggests it was never on the checklist:

- Icon-only badges use `.help(...)` as if it were a VoiceOver label — on macOS `.help` is a *tooltip*, not an accessibility label (`ClipboardItemRow.swift:18-28`). VoiceOver users get nothing.
- Filter tabs signal selection with color + font weight only (`ContentTypeFilterBar.swift:31`) — invisible to VoiceOver (no `.isSelected` trait) and to color-blind users (no shape/checkmark).
- Tab/Shift-Tab is swallowed for list navigation in both the panel and the search bar (`ClipboardPanelView.swift:249`, `SearchBar.swift:37`), so the bottom-bar buttons (Clear All, Export, Settings, Quit) are keyboard-unreachable.
- No animation in the app checks `accessibilityReduceMotion`; the "Copied" toast posts no VoiceOver announcement.

None of these are hard. Collectively they mean the app is not usable by keyboard-only or VoiceOver users, which for a utility that lives in the menu bar and is driven by a global hotkey is an odd gap. Make accessibility a line item in the PR template.

---

## 7. Testing

The pure-logic coverage (detectors, mutations, crypto, expiry, onboarding seeding) is genuinely good — deterministic, well-structured, idiomatic Swift Testing, all `struct` suites, no XCTest residue. The problems cluster exactly where I/O and async wiring live.

- **[HIGH] Tests hit the live network.** `LinkMetadataFetcherTests` (`parseTitle`, `caching`, `fetchesFavicon`) construct a real fetcher against `https://example.com`. Flaky offline/in-CI, and the "caching" test asserts nothing about caching — it would pass with caching entirely removed. Keep the excellent `isFetchableURL` parameterized tests; mock or gate the rest.
- **[HIGH] Tests mutate the real Application Support directory.** `HistoryStore` hard-codes its path, so the suite reads/writes (and deliberately corrupts) the running app's `history.enc`. Inject a base directory.
- **[HIGH] Two purpose-built mocks are dead.** `MockLinkMetadataFetcher` and `MockScreenshotWatcher` are constructed but never asserted. They represent intended coverage of the link-metadata wiring and screenshot ingestion that was never written. The secure-auto-removal fire/cancel branches and the `fetchLinkPreviews=false` suppression are likewise untested — these are the security-sensitive paths.
- **[MEDIUM] `guard case … Issue.record(); return` appears ~20 times** (most of `ClipboardMutationTests`). On failure it records *and silently no-ops the rest of the test*. A small `try #require`-based extraction helper for enum associated values removes the footgun across all of them.
- **[MEDIUM] Hand-rolled `for` loops where `@Test(arguments:)` belongs** in the detector tests — the loop form reports one failure for the whole set and stops at the first. The link-metadata tests already show the team knows the parameterized pattern; apply it.
- **Under-asserting tests:** `HexColorParserTests` only checks `!= nil`, never that `#FF5733` parses to the right RGBA — it could parse to black and pass.

Zero-coverage services: `HotkeyManager`, `ScreenshotWatcher`, `StatusBarController` + all five presenters, real `SettingsManager` persistence. The pure mapping logic inside the Carbon/dispatch-source code is extractable and worth testing even if the OS plumbing isn't.

---

## 8. What's genuinely good

A fair review names the strengths, both because they're real and because they tell the team what to keep doing:

- **Encryption at rest is done properly** — modern AEAD, key in Keychain with the right accessibility class, atomic `0o600` writes, a thought-through legacy-plaintext migration path.
- **The team thinks about security** — the SSRF filter exists at all, password managers are special-cased, `IsSecureEventInputEnabled()` is checked before synthesizing ⌘V (`ClipboardManager.swift:393`), screenshot watching uses security-scoped bookmarks. The gaps above are refinements, not a missing foundation.
- **Observability is a first-class concern** — `OSSignposter` intervals across the whole pipeline, one `Logger` category per service. Most apps this size have `print`.
- **The DI seams are real** — protocols for the pasteboard, history store, key store, mutation rules, and link fetcher mean the core *is* testable; the gap is that some seams aren't yet exercised.
- **Standards awareness** — honoring `org.nspasteboard.*` conventions, sniffing PNG magic bytes, writing three representations for SVG paste. These are details that only show up when someone cares.
- **Recent refactors moved in the right direction** — the `ClipboardManager` slim-down and presenter split are good architecture instincts; §5 is asking you to finish, not reverse, them.

---

## 9. Prioritized action plan

**Fix this week (correctness/security/data-loss):**
1. Flush on quit — wire `flushPendingSaves()` into `applicationShouldTerminate` (§2.1).
2. Close the SSRF bypasses; add a bypass-string test matrix (§1.1).
3. Single, tested password-manager bundle-ID constant incl. 1Password 8 (§1.2).
4. `onDisappear` on `KeyRecorderView` to remove the key monitor (§2.5).
5. Cap ingest size for text and images (§2.2).

**Fix this sprint (robustness/perf):**
6. Id-based selection in the panel (fixes correctness §2.4 and perf §4).
7. Move detection off the main actor / short-circuit on size (§2.3).
8. Cache filtered collections + image thumbnails + the date formatter (§4).
9. `viewDidMoveToWindow` for the floating-panel config so the privacy setting can't no-op (§2.6).
10. Isolate the test suite from the network and the real Application Support dir (§7).

**Pay down (organization/quality):**
11. Split `ClipboardItem.swift` into model + per-detector files (§5.1).
12. Finish splitting `HistoryWindowView` and `ClipboardPanelView` (§5.2).
13. Collapse the triplicated `StoredEntry` field lists (§1.4).
14. Accessibility pass: VoiceOver labels, selection traits, Reduce Motion, keyboard reachability (§6).
15. Wire up the dead mocks and the untested security-timing paths (§7).

---

## 10. Teaching notes for the team

The brief asked for this to help junior engineers grow. The recurring patterns above generalize into principles worth internalizing:

1. **Validation that runs before the dangerous operation must validate what the dangerous operation will actually use.** The SSRF filter checks the URL string; the OS resolves the hostname *after*. Always ask: "between my check and the action, what can change?" (TOCTOU thinking.) This same lesson covers the index-based selection bug — you validated an index, but the list changed before you used it.

2. **"It works because of a second mechanism" is luck, not design.** Passwords don't leak today because 1Password sets a concealed flag, masking that the bundle-ID list is stale. When something works for a reason other than the one you intended, write it down or fix it — that hidden dependency *will* break.

3. **Infrastructure you built but didn't wire up is worse than not building it** — it reads as "handled." `flushPendingSaves()` and the two dead mocks both look like the problem is solved. A reviewer skims, sees the function, moves on. If you build a safety net, connect it, and add the test that proves it catches something.

4. **The main actor is a shared, single-lane resource — treat synchronous work on it as a cost.** Twenty regex scans over an unbounded string on the UI actor is invisible until someone copies a big file. "Is this bounded? Does it belong off the main thread?" should be reflexive for anything touching user-supplied data.

5. **Duplication that must stay in sync is a latent bug, not a style nit.** The three `StoredEntry` field lists and the two password-manager ID locations don't fail loudly when they drift — they fail *silently*, which is the expensive kind. Prefer one source of truth; if you must duplicate, add a test that asserts the copies agree.

6. **Organize for the next reader, and assume the next reader is an AI with a small window.** `SecretDetector` buried in `ClipboardItem.swift` is findable by a human grep but invisible to an agent working in an open file. A pure, self-contained unit earns its own file; logic that only makes sense alongside its sibling should stay co-located. The test is always "can this be understood in isolation?"

7. **Accessibility and "what happens at the extremes" are not polish — they're the spec.** Empty history, a 200 MB paste, a VoiceOver user, a keyboard-only user, an item deleted mid-selection: these aren't edge cases to get to later, they're the cases that separate a demo from a product.

The bones here are good. Fix the data-loss and SSRF issues now, make accessibility and size-bounding part of the default checklist, and keep doing the decomposition you've already started.
