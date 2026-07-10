# Clipped — holistic code review

**Reviewer:** Principal engineer, week one on this codebase.
**Scope:** All ~12k lines of Swift under `Clipped/Sources` and `Clipped/Tests`, plus build config and entitlements.
**Date:** 2026-07-08. Supersedes the earlier review in this file — note that several older findings (e.g. "no SSRF guard at all") are now stale; the code has since added an `isFetchableURL` filter, which this review critiques for real *bypasses* rather than absence.
**Method:** Full manual read of the persistence, ingestion, concurrency, and crypto core, cross-checked by five focused review passes (security, concurrency/memory, pipeline/data-model, SwiftUI/UX, tests). Every finding below was verified against the current tree.

---

## Read this first

I was asked to criticise this as hard as I can, and I will. But let me be honest up front, because a fair review is a more *useful* review: **the bones of this project are good.** The service decomposition is clean (`ClipboardManager` genuinely is a one-sentence coordinator now), the actor boundary around `HistoryStore` is textbook, encryption-at-rest exists at all (most clipboard managers ship plaintext SQLite), `[weak self]` hygiene is near-perfect, and the test suite uses modern Swift Testing correctly. Someone here knows what they're doing.

So this review is not "the architecture is wrong." It's **"the architecture is right and the edges are unfinished."** Almost every serious problem falls into one of four buckets:

1. **Silent data loss** — the persistence layer will, under believable conditions, throw away the user's history without telling anyone.
2. **A gap between what the code claims and what it does** — doc comments and feature names promise protections (secret masking, SSRF filtering, "paste back into the source app," "restore original") that the code doesn't actually deliver end-to-end.
3. **Unbounded work on the main actor** — the ingest hot path runs on whatever the user just copied, and treats input size as friendly.
4. **Untested critical paths** — the scariest code (recovery, secure-timeout, SSRF, OCR) is exactly the code with no tests, and one test suite will delete your real clipboard history when you run it.

The recurring *lesson* for the team, and the thing I'd most want a junior engineer to internalise from this codebase: **a feature isn't done when the happy path works — it's done when it round-trips through persistence, survives a hostile input, degrades safely when a dependency is unavailable, and has a test that fails if any of that regresses.** Most bugs below are a happy path that was mistaken for a finished feature.

### Severity legend

| | Meaning |
|---|---|
| 🔴 **Critical** | Data loss, security exposure, or a headline feature that is non-functional. Fix before the next release. |
| 🟠 **High** | Wrong behaviour or a real vulnerability under believable, non-adversarial conditions. |
| 🟡 **Medium** | Noticeable defect, performance cliff, or a claim the code doesn't back up. |
| ⚪ **Low** | Polish, latent trap, or inconsistency that will bite later. |

---

## A. Data integrity & persistence — *the part that scares me*

### 🔴 A1. A transiently-wrong encryption key silently and permanently destroys the user's history — and the recovery code written to prevent this is never called

This is the finding I'd block a release on.

`HistoryStore` has a well-designed recovery story on paper. `HistoryLoadError` distinguishes `keyUnavailable`, `decryptionFailed`, and `corrupted`; `lastLoadError()` exposes it; `startFresh()` provisions a new key; and the doc comment (`HistoryStore.swift:16-24`) promises the user "is prompted to either unlock the Keychain and retry, or discard the old data and start fresh."

**None of that is wired up.** Grep the entire `Sources` tree: `lastLoadError()` and `startFresh()` have **zero callers**. The recovery enum, the error surface, and the reset path are all dead code. No view, no manager, nothing reads the load error.

Now trace what actually happens when the key is wrong (Keychain restored from another Mac, key regenerated, migration corner case):

1. `load()` calls `resolveCrypto()`, which *succeeds* — the Keychain returns a key, it's just the wrong one (`HistoryStore.swift:218-226`).
2. `crypto.decrypt()` throws → `load()` sets `loadError = .decryptionFailed` and returns `[]` **without backing up the ciphertext** (`HistoryStore.swift:162-166`).
3. Nobody reads `loadError`, so the app shows an empty history as if it were a fresh install.
4. The user, seeing an empty clipboard manager, copies something. `ingest` → `saveHistory()`.
5. `save()` does **not** check `loadError` (`HistoryStore.swift:72-112`). It re-encrypts the new, nearly-empty history with the same wrong key and `writeAtomically` **overwrites `history.enc`**.

The original ciphertext — fully recoverable with the correct key — is now gone forever. A *transient* key problem has been converted into *permanent* data loss, and the code that exists specifically to prevent this never runs.

The `keyUnavailable` path is slightly better (save refuses when `resolveCrypto()` throws) but has the same ending: if the Keychain is merely locked at launch and unlocks later, the first save after unlock overwrites the on-disk history with whatever's in memory.

**Fix:** (1) Wire `lastLoadError()` into the UI and actually present the recovery choice the doc comment promises. (2) In `save()`, refuse to write when the last load ended in `.decryptionFailed`/`.corrupted` unless the user explicitly chose "start fresh" — never silently overwrite ciphertext you failed to read. (3) Always move the unreadable file to a `.bak` before the first overwrite.

> **Lesson:** "Fails safe" means the *default, do-nothing* path preserves data. Here the default path destroys it and the safe path is opt-in code that's never invoked. If you write a recovery API, you have not finished the feature until something *calls* it — and a test proves the destructive path can't run on its own.

### 🟠 A2. Pending saves are never flushed on quit — the last thing you copied is routinely lost

`saveHistory()` debounces every write by 250 ms (`ClipboardHistory.swift:185-204`). `flushPendingSaves()` exists to drain that queue (`ClipboardHistory.swift:207-211`, forwarded at `ClipboardManager.swift:151`) — but, again, **it has no callers.** There is no `applicationWillTerminate`/`applicationShouldTerminate` in `AppDelegate` (`ClippedApp.swift`).

So: copy something, press ⌘Q within 250 ms, and the write never lands. Worse, the async enrichers (`scheduleLinkMetadataFetch`, `scheduleImageTextExtraction`) mutate items and *re-schedule* a debounced save, so freshly-fetched link titles and OCR text are especially likely to die on quit.

**Fix:** `applicationShouldTerminate` → return `.terminateLater`, `Task { await clipboardManager.flushPendingSaves(); NSApp.reply(toApplicationShouldTerminate: true) }`.

> **Lesson:** A debounce is a correctness liability at shutdown. Any time you defer a write, you owe the system a flush on every termination path — and you must call it.

### 🟠 A3. State that changes in memory but never round-trips to disk

A cluster of "the happy path works, persistence doesn't" bugs. Each individually is Medium; together they're a High because they undermine trust in the whole history.

- **`customPasteboardTypes` is stripped on every save.** `StoredEntry.strippingImageData()` — used to build *every* wire entry (`HistoryStore.swift:88-94`) — sets `customPasteboardTypes: nil` (`HistoryStore.swift:394`). The field's own comment (`HistoryStore.swift:363-366`) says it exists "so paste into the source app still works after history reload." It doesn't: after a relaunch the field is nil, so `copyToClipboard`'s custom-type replay branch (`ClipboardManager.swift:303-306`) is dead for restored items. The Logic-Pro-style profile feature silently stops working across restarts.
- **`originalContent` is never persisted.** `StoredEntry` has no field for it (`HistoryStore.swift:339-370`), so after a relaunch a mutated item still shows `wasMutated == true` (because `mutationsApplied` *is* persisted) but `restoreOriginal` finds `originalContent == nil` and no-ops (`ClipboardManager.swift:531-537`). The UI advertises "Restore original" and it does nothing.
- **`copyItem` violates its own "never drop fields" contract.** `ClipboardMutationService.swift:182-204` omits `containsSecret` and `extractedText`. Latent today only because of ingest ordering; the moment a mutation runs on an already-classified item, the secret flag is lost and a secret unmasks.
- **`moveToTop` reorders in memory but never saves** (`ClipboardHistory.swift:107-112`; callers at `ClipboardManager.swift:343, 362`). Re-copy an item, it jumps to top, relaunch, the old order is back.

**Fix:** Add the missing fields to `StoredEntry` (and stop nil-ing `customPasteboardTypes`); derive `copyItem` from a single field list so a new property can't be silently forgotten; call `saveHistory()` from `moveToTop`.

> **Lesson:** If you persist the *effect* of a change (`mutationsApplied`), you must persist the data needed to *reproduce or undo* it (`originalContent`). A "copy every field" helper is a maintenance trap the instant it's one field out of date — back it with a test that fails when the model gains a property.

### 🟡 A4. The corruption-recovery backup can only ever fire once

On valid-decrypt-but-invalid-JSON, `load()` moves `history.enc` to a **fixed** filename `history.corrupted.enc` (`HistoryStore.swift:174-177`). `FileManager.moveItem` won't overwrite, so the *second* corruption event's move fails silently (`try?`), the corrupted `history.enc` is left in place, and every subsequent launch re-hits the same decode failure and returns `[]`. The store is now wedged.

**Fix:** Timestamp/uuid-suffix the backup name, or remove the previous backup first.

> **Lesson:** "Move the bad file aside" is only idempotent if the destination name is unique. Fixed backup names turn a recoverable state into a stuck one.

---

## B. Security & privacy — *the gap between the pitch and the code*

The threat model matters here: this app persistently records **everything** the user copies — passwords, API keys, 2FA codes, private keys — and runs **with the sandbox disabled** and a network-client entitlement. Every place the code claims a protection it doesn't fully deliver is high-value. (Hardened runtime *is* enabled — `project.yml` `ENABLE_HARDENED_RUNTIME: true` — so that box is checked.)

### 🟠 B1. SSRF — link previews auto-fetch any copied URL, and the "filter" only inspects the string, not the connection

`scheduleLinkMetadataFetch` fires automatically for *any* URL that lands on the clipboard (`ClipboardManager.swift:265-282`) — no click, no confirmation, gated only by a setting that defaults to `true`. The safety check, `isFetchableURL` (`LinkMetadataFetcher.swift:65-81`), is a purely **lexical** check on the original URL string. It runs once, before DNS resolution, and the actual fetch is handed to `LPMetadataProvider` with `shouldFetchSubresources = true` (`LinkMetadataFetcher.swift:85-91`) — a black box that follows redirects you can't observe.

So a copied `https://looks-fine.example/x` that **302-redirects** to `http://169.254.169.254/latest/meta-data/…`, or whose DNS simply **resolves to** an internal address, sails straight through the filter. Copying a link is an everyday action (and pages can write to the clipboard on a click), so this is reachable without the user doing anything unusual. With the sandbox off, the request reaches whatever the host's network stack can.

**Fix:** Validate the connection you actually make, not the string you started with — resolve the host yourself, validate every resolved address, and re-validate on every `willPerformHTTPRedirection` via a custom `URLSession` delegate. Treat an un-interceptable black-box fetcher as untrusted for anything reachable on an internal network.

> **Lesson:** An allowlist checked once, before DNS and before redirects, is not a security boundary.

### 🟠 B2. SSRF filter bypasses — the IP checks are string prefixes, not parsed ranges

Even ignoring redirects, the literal checks are bypassable:

- **IPv6** (`ParsedIPv6.isPrivateOrReserved`, `LinkMetadataFetcher.swift:225-231`) never normalises the address; it string-matches `::1`, `::`, and prefixes `fe80`/`fc`/`fd`/`ff`. So `::ffff:127.0.0.1` (IPv4-mapped loopback), `::ffff:169.254.169.254` (mapped cloud-metadata), and the uncompressed `0:0:0:0:0:0:0:1` all read as *public*. `http://[::ffff:169.254.169.254]/…` is fetched.
- **IPv4** (`ParsedIPv4.init`, `LinkMetadataFetcher.swift:191-200`) parses each octet with `UInt8(part)`, which accepts `"0177"` as decimal **177**. If CFNetwork's resolver treats a leading-zero octet as **octal** (`0177` = 127), the filter sees a public address while the socket connects to loopback.

**Fix:** Parse to bytes with `inet_pton`/`inet_aton` before range-checking; explicitly unwrap `::ffff:0:0/96` mapped forms and re-run the IPv4 check on the embedded address; reject non-canonical octet encodings.

> **Lesson:** When your security filter and the OS resolver can disagree about what a string means, the attacker picks the interpretation that helps them. Never range-check IPs by string prefix — canonicalise to bytes first.

### 🟠 B3. OCR text bypasses every secret protection the app has

Commit #101 added on-device OCR. `scheduleImageTextExtraction` (`ClipboardManager.swift:284-296`) runs Vision over every copied image and stores the result in `item.extractedText`, then saves. But this path — unlike the plain-text ingest path (`ClipboardManager.swift:223-225`) — **never runs `SecretDetector`** and never sets `containsSecret`. And because `ClipboardItem.plainText` returns `nil` for images, an image is never flagged by the normal path either. Consequences:

- The UI mask (`shouldMask = (isSensitive || containsSecret) && !isRevealed`) is effectively always `false` for images.
- `ClipboardItemRow` renders `extractedText` in the clear (`ClipboardItemRow.swift:236-249`) — in the exact branch that runs when masking is off.
- Search matches `extractedText` unconditionally (`ClipboardHistory.swift:69-73`), so typeahead surfaces OCR'd secrets.

Screenshot your 2FA backup codes, a private key in a terminal, or a password-manager reveal screen, and the text is extracted verbatim and made searchable with no path through the app's own "this looks sensitive" logic.

**Fix:** Run `SecretDetector` (ideally a broader heuristic — see B4) over `extractedText` before the first save and set `containsSecret`; gate the `extractedText` preview and search behind the same mask.

> **Lesson:** When you add a new content-derived field, every downstream consumer that keys off "is this sensitive" — masking, search, persistence gating — must be re-wired to see it. Bolting a new data source onto a pipeline silently reopens the gaps the pipeline was built to close.

### 🟡 B4. Secret detection is structurally blind to the secrets people copy most

Two narrow mechanisms decide "sensitive": a **5-entry** hardcoded password-manager bundle-ID list (`ClipboardManager.swift:7-13`) plus reliance on apps voluntarily setting `org.nspasteboard.ConcealedType`; and `SecretDetector` (`ClipboardItem.swift:401-434`), whose every pattern needs a long, prefixed, high-entropy token. Neither can match a **6-digit 2FA code**, a **human/diceware password**, or a **PIN** — the short secrets users copy constantly. Dashlane, NordPass, Enpass, Keeper, Apple Passwords, and browser-native managers aren't in the list. Default retention is "never expire" (`SettingsManager.swift:207-208`), so a copied OTP sits in searchable history indefinitely.

> **Lesson:** A detector tuned for structured API-key formats protects the secrets least likely to be hand-copied and misses the ones (passwords, OTPs) copied all day. Precision-over-recall is a reasonable stance, but be honest in the UI about what it does *not* cover.

### 🟡 B5. "Reveal" is a cosmetic toggle, not access control

`isRevealed` is a plain `@State` bool flipped by a click (`ClipboardItemRow.swift:210-233`) with no `LocalAuthentication` challenge. Every context-menu action — "Paste directly," "Save as…," "Copy extracted text" — operates on the full unmasked item regardless of mask state. Ten seconds at an unlocked Mac exports the "hidden" secret with no friction. The Keychain key itself is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with no `SecAccessControl`/biometry, so there's no cryptographic backstop behind the visual mask either.

**Fix:** Gate reveal/export of masked items behind `LAContext.evaluatePolicy(.deviceOwnerAuthentication…)`.

> **Lesson:** A mask that isn't backed by an auth check is UX, not security. Don't let an affordance imply a guarantee it doesn't provide.

### 🟡 B6. Smaller security gaps

- **`containsSecret` doesn't prevent persistence.** Only `isSensitive` is filtered out of saves (`ClipboardHistory.swift:188`). A detected Stripe/GitHub key is written to disk (encrypted) and shown masked — the flag is display-only. That's a defensible design, but the naming implies stronger protection than exists; document it.
- **History directories are world-listable.** Files are written `0o600`, but the `createDirectory` calls (`HistoryStore.swift:60-65`) don't set `0o700`, so under the default umask they're `0755`. Another local user can enumerate item UUIDs, counts, and timestamps (metadata leak). Add `attributes: [.posixPermissions: 0o700]`.
- **No pattern for credentials in URLs** (`https://user:pass@host`) in `SecretDetector` (`ClipboardItem.swift:401-423`) — a common leak vector (git remotes, DB strings).
- **Auto-mutations don't rewrite the live pasteboard.** `ingest` stores the mutated item in history but never writes it back to the system pasteboard, so "Strip tracking parameters" (default ON) does **not** clean what a normal ⌘V pastes — only what you re-paste through the app. The privacy feature under-delivers.

### ⚪ B7. Pre-encryption plaintext can survive in backups

`migrateLegacyPlaintext` deletes `history.json` with an ordinary `removeItem` (`HistoryStore.swift:298-331`). Any Time Machine/iCloud/APFS snapshot taken *before* the encrypted-storage upgrade retains the old plaintext history forever. Nothing to fix in code (secure-delete is theatre on SSDs) — but it belongs in release notes for upgrading users.

> **Lesson:** "Delete the plaintext after encrypting" only protects the live filesystem going forward; it can't reach backups that already captured it.

**Verified sound (so nobody "fixes" them):** ChaChaPoly with per-message random nonces is correct AEAD; `writeAtomically` uses a `0o600` temp + `replaceItemAt`; the corruption backup moves *ciphertext*, not plaintext; `os.Logger` interpolation of clipboard content is redacted by default; `url.host` correctly ignores `user:pass@` so the host check isn't fooled by userinfo; `FileExporter` filenames are slugged and destinations come from `NSSavePanel` (no traversal).

---

## C. The clipboard pipeline — *the edge cases that were missed*

This section directly answers "what edge cases have not been spotted."

### 🟠 C1. Rich/tabular copies that also carry a bitmap are misclassified as images

`readClipboardItem` checks for an image (`.tiff`/`.png`) **before** RTF/text and takes the image branch unconditionally (`PasteboardMonitor.swift:141-152` vs `:167-217`). But Numbers/Excel/Notes/Keynote and web pages routinely put `.tiff` **and** `.rtf`/`.string` on the pasteboard together. Copy a spreadsheet range → history stores a *picture* of it. The user can't paste the values back, can't search the text, can't run text mutations on it. For a clipboard manager, faithfully preserving what was copied is the whole job.

**Fix:** Only take the image branch when there's no meaningful text representation; prefer RTF/HTML/text and keep the bitmap as a secondary rendition.

> **Lesson:** Pasteboards are multi-representation. "First matching type" ≠ "best type." Order your checks by information richness (text/RTF > rasterised preview) — apps deliberately include a bitmap fallback alongside the real content.

### 🟠 C2. No size cap anywhere on the ingest path → main-actor stalls and memory blowup

Everything on ingest runs on `@MainActor` and treats input size as friendly:

- `NSImage(data:)` **fully decodes** a raster just to read `.size` (`PasteboardMonitor.swift:143`) — `ImageProcessor.pixelSize` (ImageIO, metadata-only) already exists and should be used instead.
- `DeveloperContentDetector` + `ContentCategoryDetector` + `SecretDetector` + the whole mutation regex pipeline run across the entire string (`PasteboardMonitor.swift:202-206`, `ClipboardManager.swift:215, 223`). `SVGDetector` correctly caps its sniff at 2 KB (`ClipboardItem.swift:610`) — *none* of the others bound their input.
- Full image bytes are held in memory for up to `maxHistorySize` items; `trimToMaxSize` caps **count**, not **bytes**. Note the irony: the *rare* custom-pasteboard path caps total bytes at 2 MB (`PasteboardMonitor.swift:236-242`), but the *common* image path has no equivalent.

Copy a 200 MB TIFF or a 30 MB minified JSON blob and the UI (and the poll loop) freezes; enough large images and you OOM.

**Fix:** Cap ingest byte size (skip/downscale beyond a threshold), read image size via ImageIO, bound detector input length (`String(text.prefix(N))`), and move classification off the main actor.

> **Lesson:** Code on the ingest hot path runs on whatever the user just copied — treat input size as adversarial.

### 🟡 C3. Type handling gaps: URL read from the wrong slot; HTML and files unhandled

- **URL value is read from `.string`, not `.URL`** (`PasteboardMonitor.swift:155`). Copy a hyperlink whose anchor text is "Click here" and href is a real URL: `.URL` holds the href, `.string` holds "Click here," so `URL(string: "Click here")` is nil and the item falls through to text — no preview, no "open link." If the anchor text happens to parse as a URL, you store the *wrong* one.
- **No `public.html` branch:** browser rich copies that provide HTML + string but no RTF are stored as plain text — all formatting lost.
- **No `.fileURL` handling:** Finder file copies aren't a first-class type; copying files yields a path string or nothing.

> **Lesson:** When a type is advertised, read the value from *that* type, not from a co-present convenience type that may hold something else entirely.

### 🟡 C4. Search only matches the 200-character preview

`applyFilters` searches `item.preview` (`ClipboardHistory.swift:69-73`), and `preview` is `String(string.prefix(200))` (`ClipboardItem.swift:552-566`). Search a word at character 5,000 in a long document → no match, even though the item contains it. (Meanwhile `extractedText` *is* searched in full — an inconsistency.)

> **Lesson:** Truncating for display is fine; reusing the truncated display string as your search corpus quietly breaks search. Search the full field.

### 🟡 C5. Dedup and re-copy identity bugs

- **Re-copying a pinned item's content creates a duplicate.** `insert` dedups only against unpinned `items` (`ClipboardHistory.swift:82-85`); it never consults `pinnedItems`. Pin "foo," copy "foo" again → history shows "foo" twice.
- **Re-copying loses enriched metadata.** `insert` removes the old identical item and inserts a brand-new one (new id/timestamp), discarding the previous item's fetched `linkTitle`, `extractedText`, and `mutationsApplied`.

> **Lesson:** Dedup identity must span every collection that can hold the content, and "re-copy" should *promote and merge* the existing rich item, not replace it with a bare one.

### 🟡 C6. Rapid copies within one poll interval are silently dropped

Polling `changeCount` every 500 ms means copying A then B within the window captures only B. The code even computes `changeDelta > 1` and logs it (`PasteboardMonitor.swift:91-99`) — then ingests only the latest state.

> **Lesson:** Polling a "latest value" surface is inherently lossy under bursts. If intermediate values matter, you need push-based observation, not a faster poll — and if you accept the loss, say so instead of computing the evidence and discarding it.

### ⚪ C7. Time and formatting edge cases

- **Whitespace-only copies become blank rows:** the default-on `TrimWhitespaceMutation` turns `"   "` into `.text("")` (`ClipboardMutationService.swift:249-256`), producing an empty-preview item. Guard for post-mutation emptiness.
- **Expiry only runs on ingest** (`ClipboardManager.swift:231`), so an idle open panel shows expired items; and it's wall-clock based (`ClipboardHistory.swift:142-146`), so a large forward clock correction purges everything at once. (No DST bug — `Date` is absolute.)
- **Stored image dimensions are points, transforms are pixels** (`PasteboardMonitor.swift:146` vs `ImageProcessor.pixelSize`), so a Retina screenshot shows different dimensions before and after a transform.

### 🟡 C8. The screenshot watcher is surprising and lossy

- **Taking a screenshot force-overwrites the system clipboard.** `ingestScreenshot` calls `copyToClipboard(item)` (`ScreenshotWatcher.swift:186`), so every capture clobbers whatever the user had copied. That's destructive and unexpected (it's opt-in, but still).
- **Any new image in the watched folder is treated as a screenshot** (`imageFiles` matches png/jpg/jpeg/heic, `:207-215`). Point it at Desktop/Downloads and a saved photo or download triggers ingestion.
- **The 250 ms settle window can permanently drop a slow capture.** The filename is added to `knownFiles` *before* the delayed read (`:157` then `:161-167`); if `screencapture` hasn't flushed the bytes in 250 ms, `NSImage(data:)` fails and the file is never retried because it's already "seen."

> **Lesson:** Don't mark work "seen" before you've actually consumed it — that turns a transient failure into a permanent one. And auto-mutating the user's clipboard as a side effect of an unrelated action (taking a screenshot) is the kind of surprise that gets an app uninstalled.

---

## D. Concurrency, main-thread & resource lifecycle

Credit first: **no data races were found.** The debounce snapshots value-type `StoredEntry`s on the main actor before crossing into the `HistoryStore` actor, so the mutable `@MainActor ClipboardItem` never crosses isolation domains; crypto/Keychain/file IO all live on the actor; the secure-timeout task correctly propagates cancellation instead of the classic `try?`-fires-on-cancel bug; the Carbon C-trampoline captures nothing and hops to `@MainActor` with only a `UInt32`. That's the hard stuff done right.

The problems are about *where long work runs* and *what never gets torn down*.

### 🟠 D1. CPU-bound work runs synchronously on the main actor

- **Image transforms** (`compressImage`/`convertImage`/`resizeImage` → `applyImageTransform`, `ClipboardManager.swift:498-529`) do a full ImageIO decode+encode on the main thread from a menu action. Beachball on a 20 MP image. `ImageProcessor` is already a pure `Data → Data` — wrap it in `Task.detached(.utility)` (the OCR path is the template).
- **Screenshot ingest** reads bytes and decodes on the main actor (`ScreenshotWatcher.swift:170-192`); the directory enumeration (`contentsOfDirectory`) also runs on main and scales with folder size.
- **Per-copy text analysis** (dev-content/categories/secret/mutations) runs on main for every copy (see C2).

> **Lesson:** `@MainActor` is about *where* code runs, not *how long*. A `Task { @MainActor … }` inside a background dispatch-source handler pulls work *onto* the main thread — the hop is the opposite of offloading.

### 🟡 D2. The poll timer is on the wrong run-loop mode and never coalesced

`Timer.scheduledTimer` installs in `.default` mode (`PasteboardMonitor.swift:60-64`), so clipboard monitoring **pauses during any tracking loop** — an open menu, a window resize, `NSOpenPanel.runModal()`. No `tolerance` is set, so the system can't batch the 2 Hz wakeups (a top Energy-impact pattern), and there's no sleep/wake or active/inactive awareness.

**Fix:** `RunLoop.main.add(timer, forMode: .common)` (or a `DispatchSourceTimer`) with generous `leeway`/`tolerance`; pause on `applicationDidResignActive`.

### 🟡 D3. Missing `deinit`s leak a live timer and a file descriptor

- `PasteboardMonitor` has no `deinit`; the run loop retains the repeating timer, so an instance dropped without `stopMonitoring()` keeps firing every 0.5 s forever against a nil `weak self`. Every `ClipboardManager()` a test builds is a candidate. Add `deinit { pollTimer?.invalidate() }`.
- `ScreenshotWatcher` closes its fd only in the dispatch source's cancel handler, and has no `deinit`; an instance deallocated while watching leaks the fd and a resumed source. Add `deinit { dispatchSource?.cancel() }`.

> **Lesson:** A repeating `Timer` outlives its owner because the *run loop* holds the strong reference, not the owner. A resumed `DispatchSource` dropped without `cancel()` may never run its cancel handler. Long-lived OS resources need explicit teardown.

### 🟡 D4. Unbounded fire-and-forget enrichment

Every ingested URL/image spawns an untracked `Task` (`ClipboardManager.swift:265-296`) with no concurrency cap and no cancellation on `clearAll`/removal/quit. A paste-storm of 50 images launches 50 concurrent Vision OCR jobs.

**Fix:** Funnel enrichment through a bounded `TaskGroup`/queue and store handles so `clearAll` can cancel.

> **Lesson:** Fire-and-forget `Task {}` is structured concurrency with the structure removed. Under load it becomes an implicit thread bomb.

---

## E. UI / UX / accessibility

### 🔴 E1. The panel steals focus and never restores it — auto-paste pastes into Clipped itself

The presenters call `NSApp.activate(ignoringOtherApps: true)` *before* showing the panel so the search field can take first responder (`ClipboardPanelPresenter.swift:116, 156`). That makes Clipped frontmost. Then:

- `pasteDirectly` copies and, 100 ms later, synthesises ⌘V (`ClipboardItemRow.swift:154-160` → `simulatePaste`) — but Clipped is still key, so ⌘V lands in Clipped's own search field. It also never dismisses the panel first.
- `pasteMatchingStyle` reads `NSWorkspace.shared.frontmostApplication` *after* activation (`ClipboardManager.swift:418`), so `targetApp` is Clipped, the `guard` always passes, and it pastes into Clipped.

Every auto-paste path is non-functional. (The primary click path works only because dismissing the transient popover happens to return focus to the previous app.)

**Fix:** Snapshot `frontmostApplication` *before* `NSApp.activate`, then reactivate that app and order the panel out *before* synthesising ⌘V.

> **Lesson:** A menu-bar app that activates itself for keyboard focus must remember who was frontmost first, or its own keystrokes land in its own process.

### 🟠 E2. Filtering is O(n²) per render and re-runs on every keystroke

`filteredItems`/`filteredPinnedItems` are **uncached** computed properties that filter + case-insensitive-search on every access (`ClipboardHistory.swift:37-76`). In the panel, `isSelected: indexOf(item) == selectedIndex` calls `indexOf` **once per row**, and `indexOf` rebuilds `allVisibleItems` each time (`ClipboardPanelView.swift:200, 449-451, 36-38`) — O(n) filter builds × n rows. The whole panel is one computed property bound to `manager.searchQuery`, so each keystroke reruns the entire O(n²). The history window recomputes its merged+filtered list ~10× per render with no search debounce (`HistoryWindowView.swift:290-331`).

**Fix:** Derive the filtered list once into a `let` at the top of `body`, precompute an `[id: index]` map, and debounce search.

> **Lesson:** Computed properties on an `@Observable` re-execute on *every* access. Derive once, pass down.

### 🟠 E3. Full-resolution images decoded on the main thread inside row bodies

`NSImage(data:)` runs in the view body for every row, every render — including during scroll as rows recycle — decoding multi-MB originals to draw a 28–48 pt thumbnail, with no cache (`ClipboardItemRow.swift:237, 253`; `HistoryWindowView.swift:517-539`). This is the main scroll-jank source.

**Fix:** Generate a downsampled thumbnail once off-main (`CGImageSourceCreateThumbnailAtIndex`), cache by `item.id`.

### 🟠 E4. Panel rows are `onTapGesture`, invisible to VoiceOver and keyboard

`ClipboardItemRow` is a plain `HStack` whose only activation is a tap gesture (`ClipboardItemRow.swift:37-48`), with no button trait or accessibility action. VoiceOver reads the row but VO-Space does nothing; there's no focus ring. The panel's core action is unreachable without a mouse. (The history `List` is a real selectable list and is fine.)

**Fix:** Wrap in a `Button(.plain)` or add `.accessibilityAddTraits(.isButton)` + `.accessibilityAction`.

### 🟠 E5. Selection is a positional `Int` into a list that mutates underneath it

`selectedIndex: Int?` (`ClipboardPanelView.swift:19`) indexes `allVisibleItems`. Copy something while the panel is open → `insert` puts it at index 0, so `selectedIndex` now points at a *different* item and Return copies the wrong one. Deletion shifts indices without updating selection.

**Fix:** Track selection by `ClipboardItem.ID`.

> **Lesson:** When the backing collection can change under you, track selection by stable identity, never by array position.

### 🟡 E6. Medium UI issues

- **Wrong empty state for "no search results"** — the "Copy something to get started" empty view fires when a filter/search excludes everything (`ClipboardPanelView.swift:174-176, 302-317`), implying the history was wiped. Branch on `items.isEmpty` vs an active query.
- **Reduce Motion is never consulted** despite slide/scale animations (`OnboardingView`, `ContentTypeFilterBar`, the copied-toast). Gate decorative motion on `@Environment(\.accessibilityReduceMotion)`.
- **Deprecated `activate(ignoringOtherApps:)`** at 8 sites (macOS 14+). Note: this interacts with E1 — it's not a blind find-and-replace.
- **Two parallel settings surfaces** — the SwiftUI `Settings` scene (⌘,) and a hand-rolled `NSWindow` from the panel gear button can both be open at once (`ClippedApp.swift:129-134` vs `SettingsWindowPresenter`).
- **Fixed panel/onboarding dimensions clip at large Dynamic Type** (`StatusBarController.swift:12-13`; onboarding content isn't in a `ScrollView`).
- **No 1–9 number-key quick-paste**, and Return with no selection is silently swallowed (`ClipboardPanelView.swift:233-256, 411-416`).

**Verified good:** modern APIs throughout (`foregroundStyle`, `NavigationSplitView`, `.clipShape(.rect(cornerRadius:))`, two-param `onChange`, `@Bindable` locals); icon buttons use `Label` + `.help` so VoiceOver gets names; windows are reused (`isReleasedWhenClosed = false`) — no leaks; async staleness is guarded by re-checking item id.

---

## F. Testing

The suite is *well-built where it exists*: all structs (no `XCTestCase`), good parameterised tables, real DI through `MockPasteboard`/`MockHistoryStore`, and `IntegrationTests` genuinely wires monitor→ingest→history→store. The problem is **what's tested**, not **how**.

### 🔴 F1. `HistoryStoreTests` reads and deletes your real clipboard history

`HistoryStore.init` hard-codes `~/Library/Application Support/Clipped/` with no directory injection (`HistoryStore.swift:56-65`), and `HistoryStoreTests` resolves that same real path (`HistoryStoreTests.swift:349-351`) and calls `store.clear()` in nearly every test — which removes `history.enc` and the `images/` dir. **Running `make test` on any machine with the shipping app installed wipes the user's actual encrypted history.** `.serialized` prevents intra-suite races but does nothing about clobbering real data.

**Fix:** Inject the base directory so `HistoryStore` can be pointed at a per-test `FileManager.temporaryDirectory`. This is the single most important test change.

> **Lesson:** Production code that touches the filesystem must take its base directory as an init parameter. Never let a test's teardown delete a real user file.

### 🟠 F2. Non-hermetic tests: live network and shared `UserDefaults`

- `LinkMetadataFetcherTests` fetch `https://example.com` for real (`:9-13, 24-32, 68-74`) — flaky offline/CI, slow — and two of them assert nothing meaningful (the "caching" test proves nothing because it never checks fetch count; the favicon test only asserts `title != nil`).
- `SettingsManagerTests` build the real `SettingsManager()`, whose init reads `UserDefaults.standard` and `SMAppService` (`:6-28`), so a developer who changed a setting fails these. `OnboardingSeederTests` already shows the right pattern (per-test `UserDefaults(suiteName:)`) — copy it.

> **Lesson:** To test a cache, assert the collaborator was called exactly once (a spy), not that two calls return equal values. And never let a test's name promise a behaviour its assertions don't check.

### 🟠 F3. The scariest code has no tests

- **SSRF filter** — no IPv4-mapped-IPv6, octal-IP, or redirect cases (exactly the B1/B2 bypasses).
- **Secure-timeout auto-removal** never actually fires — the one test sets `secureTimeout = 30` so it *can't* elapse (`IntegrationTests.swift:108-127`), and cancellation-suppresses-removal is untested. Inject a `Duration` so it can be driven to zero.
- **`HistoryStore` recovery branches** (`keyUnavailable`, valid-decrypt-but-garbage-JSON backup) — untested; needs a throwing key-store mock.
- **Whole services with zero tests:** `ImageTextExtractor` (the entire OCR feature + its ingest wiring), `HotkeyManager` (`formatShortcut`/`keyName` are pure functions needing no Carbon), `ScreenshotWatcher` (a `MockScreenshotWatcher` exists but nothing uses it), all presenters and views.
- **Tautological/weak tests:** `restoreOriginal` never calls production code (`ClipboardMutationTests.swift:156-178`); hex-color tests assert only `!= nil`, so a channel swap in `HexColorParser.parse` passes; injected `MockLinkMetadataFetcher.fetchCallCount` is incremented but never asserted.

> **Lesson:** If a test doesn't call a function from the system under test, it's testing itself. Pull the pure, deterministic pieces (shortcut formatting, OCR result assembly, IP parsing) out of the system-dependent shell and test *those* — "it uses Carbon/Vision/the network" is not a reason to leave the logic untested.

---

## G. Smaller code-quality notes

- **Inconsistent `maxHistorySize` default:** `SettingsManager` says 100 (`:205`), `ClipboardHistory`/`ClipboardManager` fall back to 50. Production uses 100; the 50 is a silent phantom. One constant, referenced from both.
- **Mutation ordering bug:** `StripToPlainTextMutation` runs before `ConvertToMarkdownMutation` (`ClipboardMutationService.swift:161-173`), and the former converts `.richText → .text`, so if both are enabled, markdown conversion is dead. Both default off, so latent — but ordering-dependent pipelines need a test.
- **`DetectCodeSnippetMutation` over-triggers:** "2+ lines ending in `;{}` or `)`" (`:507-508`) flags citation lists and prose as code.
- **Duplicated JWT regex** in `SecretDetector` and `DeveloperContentDetector`.
- **Dead code:** `watchedFD` is written but never read (`ScreenshotWatcher.swift:36`); `extension ContentType: Equatable {}` is redundant on a String enum (`ContentTypeFilterBar.swift:39`); `MockScreenshotWatcher` is unreferenced.
- **`requestNotificationPermission()` prompts on every launch** even when screenshot capture is disabled (`ClippedApp.swift:23`).
- **`RelativeDateTimeFormatter` allocated per row per render** (`HistoryWindowView.swift:755-760`) — prefer `Text(date, format: .relative(...))`.

---

## H. What's genuinely good (learn from these too)

A review that only lists faults teaches juniors that good work is invisible. It isn't:

- **The actor boundary is correct.** Value-type `StoredEntry` snapshots cross into `HistoryStore` on the main actor; no mutable class ever crosses isolation. This is how you do Swift 6 concurrency.
- **`[weak self]` discipline is near-perfect** across timers, dispatch sources, the Carbon trampoline, and every enrichment task. No retain cycles found.
- **Cancellation is handled correctly** in the secure-timeout task (propagates cancellation rather than the `try?`-fires-on-cancel footgun) and the save debounce.
- **Encryption-at-rest exists and is AEAD**, with atomic `0o600` writes and a plaintext-free corruption backup.
- **The `2 MB` cap on custom-pasteboard snapshots** shows the right instinct (bound adversarial input) — it just needs to be applied to the common image path too.
- **The test *framework* usage is modern and correct**, and `OnboardingSeederTests` is a model of hermetic setup.

---

## I. If I could only fix ten things, in order

1. **A1** — stop `save()` from overwriting ciphertext it failed to decrypt, and wire up the recovery UI that already exists. *(Prevents permanent, silent data loss.)*
2. **F1** — inject the storage directory so tests can't delete real history.
3. **A2** — flush pending saves on `applicationShouldTerminate`.
4. **B1/B2** — validate the actual connection (redirects + resolved IP) in the link fetcher; parse IPs to bytes.
5. **B3** — run secret detection over OCR text and mask/gate it.
6. **C2 + D1** — cap ingest input size and move image/text/OCR work off the main actor.
7. **C1** — prefer text/RTF over a co-present bitmap on ingest.
8. **E1** — restore the previous app's focus before synthesising ⌘V.
9. **A3** — persist `customPasteboardTypes` and `originalContent`; save on `moveToTop`.
10. **E2/E3** — memoise the filtered list once per render and thumbnail-cache decoded images.

The throughline for the team: **finish features to the point where they survive persistence, hostile input, an unavailable dependency, and a regression test.** The craft here is real — it just needs to be carried all the way to the edges.
