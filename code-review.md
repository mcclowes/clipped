# Clipped — senior code review

> Reviewer persona: principal engineer, fresh to the codebase, unimpressed.
> Target audience: the team's more junior engineers. The goal of this review
> is not to make anyone feel bad — it's to point at real problems, explain
> the underlying principle, and leave you with a better sense of what good
> looks like.

This review covers every source file in `Clipped/Sources/` plus the test
harness and project config, as of commit `74bc0af`. I've cross-checked
against Swift 6 strict concurrency, SwiftUI Observation, macOS HIG, and
general data-race / persistence correctness.

---

## 0. Executive summary

The app works. That isn't the same as being well engineered. The biggest
structural issues I'd fix before adding a single new feature:

1. **`ClipboardItem` is a reference type but not `@Observable`.** Every
   view that shows `item.linkTitle`, `item.isPinned`, `item.wasMutated`
   etc. is silently **not** reactive. Async mutations (link metadata
   fetch, pin toggle, mutation restore) do not redraw the UI reliably.
2. **Service wiring is done post-construction in `AppDelegate`.** By the
   time `cm.settingsManager = sm` runs, `ClipboardManager.init()` has
   already started polling. There's a visible race between "first poll"
   and "history loaded from disk" that can permanently hide persisted
   items. This is a real, reproducible data-loss bug.
3. **Disk I/O on the main actor on every clipboard event.** `HistoryStore`
   is `@MainActor`, JSON-encodes the entire history (images included,
   base64-inflated), and is called synchronously from every copy, pin
   toggle, mutation, and async side-effect. The app will hitch as soon as
   a user copies a few screenshots.
4. **Singletons eat the DI design.** You took the trouble to define
   protocols (`HistoryStoring`, `SettingsManaging`, `LinkMetadataFetching`,
   `ClipboardMutating`) and then hard-wired `.shared` instances as
   defaults. The protocol work is half-finished.
5. **Polling everything, all the time.** 0.5s pasteboard polling *plus*
   1s screenshot folder polling *plus* synchronous disk writes. This is a
   menu-bar utility — it will visibly burn battery.
6. **Accessibility is effectively absent.** Icon-only buttons with no
   labels, fixed point sizes, hover-to-reveal controls, no Dynamic Type.
   A VoiceOver user cannot use this app at all.
7. **Many, many edge cases around clipboard content types, encodings,
   paste origins, and mutation ordering are simply not considered.** I
   list ~30 of them below.

None of this is catastrophic. All of it is fixable incrementally. But
today the project is in the dangerous middle ground where it *looks*
polished enough that nobody will go back and fix the foundations unless
someone explicitly asks.

---

## 1. Critical bugs (do these first)

### 1.1 `ClipboardItem` is not observable — the UI lies to you

**File:** `Sources/Models/ClipboardItem.swift:109-172`
**File:** `Sources/Services/ClipboardManager.swift:208-213`

`ClipboardItem` is a `@MainActor final class`, stored by reference inside
the `@Observable ClipboardManager`. Views hold references to these items
(`ClipboardItemRow.item`, `StickyNoteView.item`, etc.) and then read
mutable properties: `item.linkTitle`, `item.linkFavicon`, `item.isPinned`,
`item.wasMutated`, `item.isSensitive`, `item.content`.

SwiftUI's Observation framework **only tracks property access on types
marked `@Observable`**. Because `ClipboardItem` is not, mutating any of
those properties after the view has rendered produces **no redraw**.

Concretely, this async block in `ClipboardManager.checkClipboard` is
dead code for UI purposes:

```swift
// ClipboardManager.swift:207-214
if case let .url(url) = item.content {
    Task {
        let metadata = await linkMetadataFetcher.fetchMetadata(for: url)
        item.linkTitle = metadata.title
        item.linkFavicon = metadata.favicon
        saveHistory()
    }
}
```

The row renders once with `linkTitle == nil`, then the metadata arrives,
and the row never updates — until some other state change on the
`ClipboardManager` forces a rerender and drags the row along for the ride.
Users see "this URL has a title sometimes, and sometimes not." That's
exactly the symptom of accidental non-reactivity.

Same bug for pin toggle (`togglePin` mutates `item.isPinned` in place),
for `restoreOriginal` (mutates `item.content` and `item.mutationsApplied`
in place), and for the "reveal sensitive" button (toggles `item.isSensitive`
indirectly via `isRevealed` — that one is local `@State` so it survives by
accident).

**Fix (pick one):**

- **Option A (preferred):** Make `ClipboardItem` a value type (`struct`)
  and update everything via `ClipboardManager`. Identity becomes the
  `id: UUID`. The mental model becomes much simpler: the only mutable
  owner of clipboard state is `ClipboardManager`. This also trivially
  fixes race issues below.
- **Option B:** Mark `ClipboardItem` as `@Observable`. You still carry
  the reference-semantics footguns, but at least the UI updates.

Option A is what I'd do. Every in-place mutation in `ClipboardManager`
(`togglePin`, `restoreOriginal`, async link metadata fetch, secure
auto-expiry) currently gets away with something it shouldn't: it's
sharing a class instance across the collection, mutation, and view, and
relying on SwiftUI's diffing to paper over the result. Value types force
you to write the right code.

### 1.2 Race: persisted history is dropped if you copy anything in the first ~500ms

**File:** `Sources/App/ClippedApp.swift:16-34`
**File:** `Sources/Services/ClipboardManager.swift:104-114`

Sequence of events at launch today:

1. `ClippedApp` init → `AppState.shared` init → `ClipboardManager()` init.
2. `ClipboardManager.init` immediately calls `startMonitoring()` — timer
   installed, polling starts.
3. Polling fires at most 0.5s later, and reads from the pasteboard. If
   anything is there (almost always true), it inserts an item into
   `self.items`.
4. Eventually `AppDelegate.applicationDidFinishLaunching` runs, sets
   `cm.settingsManager = sm`, and *then* calls `cm.loadPersistedHistory()`.
5. `loadPersistedHistory` contains:

   ```swift
   if items.isEmpty { items = loaded }
   if pinnedItems.isEmpty { pinnedItems = pinned }
   ```

   If the poll in step 3 already ran, `items.isEmpty == false` and **the
   persisted history is silently discarded**.

This is data loss. It's probabilistic (depends on timing, whether the
pasteboard had content, etc.) which is the worst kind of bug because it
looks like "sometimes the history is empty after a reboot" and nobody
can reproduce it on demand.

**Fix:**

- Do not start monitoring inside `ClipboardManager.init()`. Add an
  explicit `bootstrap(settings:history:...)` method that the AppDelegate
  calls after wiring dependencies. That method loads persistence first,
  then starts monitoring.
- While you're at it: remove the `init()` side-effect entirely. Every
  time you see a class whose `init()` starts timers, takes locks, or
  touches global state, that's a code smell. `init` should be boring.

### 1.3 `HistoryStore.save` runs on the main actor and JSON-encodes images

**File:** `Sources/Services/HistoryStore.swift:13-48`
**File:** `Sources/Services/ClipboardManager.swift` (every mutation)

`HistoryStore` is `@MainActor`, and `save(items:pinnedItems:)` does the
following on the main thread on every single clipboard change:

- Filters the history (`!isSensitive`).
- Maps each item through a `StoredEntry` initializer.
- JSON-encodes the lot. Images (`.image(Data, CGSize)`) end up base64'd
  inside JSON, inflating raw bytes by ~33%.
- Writes the file to disk (synchronously).
- Atomically replaces the existing file.

On a user who copies a single 4K screenshot (say 4 MB), every subsequent
unrelated copy re-encodes and re-writes ~5 MB of JSON on the main
thread. The UI hitches are going to be very visible, especially because
this same path is called synchronously from `checkClipboard`, which is
itself called from a 0.5s timer on the main actor.

**Fix:**

- Make `HistoryStore` an `actor`, not `@MainActor`. It has no UI
  affinity — it's a disk writer. That's the entire job of non-main
  actors in Swift 6.
- Store images as separate files on disk, with the JSON index pointing
  at them. No base64, no re-encoding every write.
- Debounce saves: after a burst of mutations, coalesce into one write
  within e.g. 500ms. `AsyncStream` + a dedicated consumer task is the
  idiomatic Swift 6 way.
- Migrate `StoredEntry` off `@MainActor` — it's a Codable value type, it
  has no business being main-actor-isolated. That annotation is load-
  bearing for no reason other than that it lives in a file that already
  imports `@MainActor`.

### 1.4 Clear-all undo silently corrupts order and drops pins

**File:** `Sources/Views/ClipboardPanelView.swift:248-275`

```swift
Button("Clear All") {
    recentlyClearedItems = manager.items  // pinned items NOT captured
    manager.clearAll()
    ...
}
...
Button("Undo") {
    if let cleared = recentlyClearedItems {
        for item in cleared.reversed() {
            manager.items.append(item)   // reverses original order
        }
    }
}
```

Two bugs in five lines:

1. `recentlyClearedItems` only stores `manager.items`, not
   `manager.pinnedItems`. `clearAll()` leaves pins alone by default so
   this is accidentally fine today — but the symmetry is broken and the
   next person to refactor will get this wrong.
2. Restoring with `.reversed().append` reverses the order. A freshly
   undone history is backwards. The direct fix is `manager.items = cleared`,
   but see the bigger point below.

**Also:** the 3-second cleanup `Task` has no cancellation. If the user
clears again, undoes, and clears again within 3s, you end up with the
first task clobbering `recentlyClearedItems` while the second clear is
still live.

**Fix:** move this undo state into `ClipboardManager` where it belongs,
hold *both* unpinned and pinned snapshots, use a single debounced
cancellation task, and restore via assignment.

### 1.5 Copying an image back to the pasteboard lies about the format

**File:** `Sources/Services/ClipboardManager.swift:301-321`

```swift
case let .image(data, _):
    pasteboard.setData(data, forType: .tiff)
```

`data` may well be PNG bytes (see `readClipboardItem`, which accepts
`.tiff` *or* `.png` and stores whichever raw bytes it found). Advertising
PNG bytes under the `.tiff` pasteboard type is incorrect and will break
pasting in apps that trust the type declaration.

**Fix:** carry the original format in `ClipboardContent.image`:
`case image(Data, CGSize, NSPasteboard.PasteboardType)`. Or, at copy
time, sniff the bytes (TIFF magic `II*\0` / `MM\0*`, PNG magic
`\x89PNG`) and advertise the right type.

### 1.6 `isCheckingClipboard` guard is dead code; the real issue is polling on main

**File:** `Sources/Services/ClipboardManager.swift:152-156`

```swift
guard !isCheckingClipboard else { return }
isCheckingClipboard = true
defer { isCheckingClipboard = false }
```

`ClipboardManager` is `@MainActor`. The main actor is serial. There is
no way for two invocations of `checkClipboard()` to overlap. This guard
is a tell that somebody was worried about re-entrancy but couldn't
reason about it.

Delete it. Replace the comment with one sentence explaining the main-
actor invariant so the next reader doesn't re-add the guard.

### 1.7 `withMonitoringPaused` tears down and rebuilds the timer on every paste

**File:** `Sources/Services/ClipboardManager.swift:140-150`

Every copy-to-clipboard, every copy-as-plain-text, every export, every
mutation restore calls `withMonitoringPaused`, which:

1. Cancels any in-flight resume task.
2. Invalidates the Timer and creates a new one 200ms later.
3. Resumes monitoring via a new scheduled Timer.

If a user spam-copies items, you're allocating and destroying `Timer`s
at that rate. Worse, between the pause and the resume, *any* change the
user makes to the clipboard outside the app is silently ignored — the
`lastChangeCount = NSPasteboard.general.changeCount` assignment after
`body()` papers over it.

**Fix:** don't pause the timer at all. Instead, capture the change count
immediately before your write, and when the next poll fires, ignore
changes whose count is less than or equal to yours + 1 (your own write).

Or, better, move off Timer polling entirely — see 2.3.

### 1.8 `SmartQuotesToStraightMutation` is O(n²) on string length

**File:** `Sources/Services/ClipboardMutationService.swift:311-323`

```swift
var result = string
for (smart, straight) in Self.replacements {
    result = result.map { $0 == smart ? straight : $0 }
        .reduce(into: "") { $0.append($1) }
}
```

For each of the four replacements, this walks every character, builds an
intermediate `[Character]`, then reduces back into a String by appending
one Character at a time. That's O(4n) allocations and four full copies
of the string. On a 100 KB paste this is hundreds of milliseconds on the
main thread.

The idiomatic version is one pass:

```swift
let result = String(string.map { c -> Character in
    switch c {
    case "\u{2018}", "\u{2019}": "'"
    case "\u{201C}", "\u{201D}": "\""
    default: c
    }
})
```

Or, with `replacingOccurrences`, four scans but no per-character
allocation churn. Still beats the current implementation by an order of
magnitude.

### 1.9 `launchAtLogin` didSet can recurse on failure

**File:** `Sources/Services/SettingsManager.swift:78-91`

```swift
var launchAtLogin: Bool {
    didSet {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            ...
            launchAtLogin.toggle()
        }
    }
}
```

`launchAtLogin.toggle()` inside didSet re-enters didSet in Swift. If the
register call keeps failing, you're about to thrash. Use a private
`_launchAtLogin` backing property, or guard with a `isReverting` flag,
or — better — model the intent/result split explicitly: "the user asked
for X" vs "the system is in state Y." Today they're mashed together.

Also: the error is logged and swallowed. The user gets no feedback. They
flip a toggle, it bounces back, and they have no idea why. Surface an
alert.

### 1.10 Global hotkey registration has no error path

**File:** `Sources/Services/HotkeyManager.swift:57-64`

`RegisterEventHotKey` returns `OSStatus`. It's ignored. If the hotkey
conflicts with another app (Spotlight, CleanShot X, other clipboard
managers), registration fails silently and the UI happily shows "⌥C"
as if everything is wired.

**Fix:** check the return value. If non-zero, surface a settings error
banner: "Your shortcut conflicts with another app. Pick a different
one." And `InstallEventHandler` return value is also ignored — same
treatment.

---

## 2. Architecture concerns

### 2.1 Singletons defeat your own DI

You defined `HistoryStoring`, `SettingsManaging`, `LinkMetadataFetching`,
`ClipboardMutating`. Good. Then you wired them with `.shared` instances
as defaults and stored them as mutable public properties that get
assigned in `AppDelegate`. This is the worst of both worlds:

- Your tests can swap them in (✓).
- But production reads from singletons, so any bug in the wiring order
  silently falls back to the live disk store.
- `LinkMetadataFetcher.shared` is a stored property on a type that your
  tests can't override globally.
- `HotkeyManager.shared` and `StatusBarController.shared` are straight
  singletons that are never swapped out anywhere.

**What to do:** own one composition root. That root is your `AppDelegate`
(or a dedicated `AppEnvironment`). Construct every service there. Pass
them in via initializers, not via mutable properties. `AppState.shared`
becomes an anti-pattern to delete.

### 2.2 `ClipboardManager` is a god object

It holds:

- Clipboard polling state.
- The history, pinned items, filters, search query, "opened via hotkey"
  UI transient state.
- Dependencies on settings, history store, link metadata, mutation
  service.
- Direct responsibility for applying filters, deduping, trimming,
  mutating items, copying to pasteboard, pasting, playing sounds,
  exporting, restoring, and secure-mode scheduling.
- Accessory helpers (`recentSourceApps`) that exist only for the
  settings UI.

437 lines is not "a lot" as lines go — the problem is that the
responsibilities don't factor cleanly. A clean split:

- **`PasteboardMonitor`**: owns polling, reads `NSPasteboard`, emits
  typed `ClipboardEvent`s.
- **`ClipboardHistory`**: holds items + pins, exposes filter/search,
  handles dedup/trim.
- **`PasteboardWriter`**: writes back to pasteboard, simulates paste,
  handles sound.
- **`ClipboardPipeline`**: glues them together and applies the mutation
  pipeline.

This isn't a rewrite; you can do it a slice at a time. Start with pulling
`filteredItems` / `filteredPinnedItems` / `selectedFilter` / `searchQuery`
out into a `ClipboardFilterState` struct the view owns. Your view tests
and manager tests will stop overlapping.

### 2.3 Polling is a last resort, not a default

Two separate polling loops:

- Pasteboard: 0.5s (`ClipboardManager.startMonitoring`).
- Screenshot folder: 1.0s (`ScreenshotWatcher.startWatching`).

The screenshot folder one is inexcusable — macOS has had FSEvents
(`DispatchSource.makeFileSystemObjectSource` or `FSEventStreamCreate`)
since forever. You get push notifications and zero poll cost.

The pasteboard one is trickier because AppKit doesn't surface pasteboard
change events. But you can still:

- Reduce frequency when the app is inactive (`NSApplication.didResignActiveNotification`).
- Use a `DispatchSourceTimer` on a background queue and hop to main
  only when `changeCount` actually changed.
- Or, since this is Swift 6, express it as an `AsyncStream` driven by
  a `Task` with `ContinuousClock().sleep(for:)`, and `break` on app
  termination. That gives you proper cancellation for free.

### 2.4 `AppState.shared` uses `class + static let` instead of a proper environment

```swift
@MainActor
final class AppState: Observable {
    static let shared = AppState()
    ...
}
```

Minor but worth pointing out for juniors: `Observable` is not the same
as `@Observable`. The conformance here does nothing unless you apply the
macro. This type is pretending to participate in Observation and isn't.
It happens not to matter because you only read `AppState` properties
from places that don't need to react, but if you add state to it, it
won't work the way you expect.

### 2.5 Two menu implementations for the same row

`ClipboardItemRow` has both a SwiftUI `.contextMenu` and a hand-rolled
`NSMenu` built via `showNSActionMenu()` with an `ActionMenuTarget`
Objective-C shim. The AppKit one is invoked for option-click. Double
maintenance cost, different item sets (the SwiftUI menu is missing
"Paste directly" and "Delete"; the NSMenu is missing "Paste and match
style"). Inevitably they'll drift further apart.

Pick one. SwiftUI's `.contextMenu { }` supports images now, handles
`Label` with system symbols, and removes the entire `ActionMenuTarget`
/ `objc_setAssociatedObject` hack (which, by the way, uses a
string-literal associated-object key, which is undefined behavior — the
key must be a stable void pointer).

### 2.6 `copyItem` silently drops item metadata during mutation

**File:** `Sources/Services/ClipboardMutationService.swift:180-194`

```swift
@MainActor
private func copyItem(
    _ item: ClipboardItem,
    content: ClipboardContent
) -> ClipboardItem {
    ClipboardItem(
        id: item.id,
        content: content,
        contentType: item.contentType,
        sourceAppName: item.sourceAppName,
        sourceAppBundleID: item.sourceAppBundleID,
        timestamp: item.timestamp,
        isPinned: item.isPinned,
        isSensitive: item.isSensitive
        // ⚠️ silently drops: isDeveloperContent, linkTitle, linkFavicon,
        //    originalContent, mutationsApplied
    )
}
```

This is a time bomb. The `DetectCodeSnippetMutation` is currently last in
the pipeline, so nothing depends on `isDeveloperContent` being preserved
across a later mutation. If anyone re-orders the pipeline, or inserts a
new mutation between URL mutations and the plain-text ones, developer
tagging will mysteriously stop working.

Further: because `ClipboardItem` is a class, the right primitive here
isn't "copy all fields except content" — it's "give me a new instance
with content replaced." With `ClipboardItem` as a struct (see 1.1),
this becomes `var copy = item; copy.content = content; return copy`.
No footgun.

### 2.7 Mutations are not persisted and `restoreOriginal` is lossy

**File:** `Sources/Services/HistoryStore.swift:97-155`

`StoredEntry` persists `isDeveloperContent` but not `originalContent` or
`mutationsApplied`. On reboot, every item is "clean" — the purple wand
badge is gone, and the "Restore original" context menu item vanishes
even though the mutation is still applied. Users lose the ability to
undo a transformation across a session boundary.

Either persist the full pre-mutation state or commit to "mutations are
permanent across sessions, here's the reasoning."

### 2.8 `StatusBarController` mixes popover, panel and windows in one shared object

The controller manages:

- The status bar item.
- An `NSPopover` (used when the user clicks the status bar icon with the
  mouse on the same screen).
- An `NSPanel` (used when the user triggers from the other monitor).
- A one-off onboarding window.
- A one-off settings window.

Three different presentation models for "show some SwiftUI." Each one
fakes the others: `showAsPanel` shoves the popover's `NSHostingController`
into the panel (so they share one view hierarchy — if both are ever
shown, you'll get "view has superview" runtime errors). `closePanel`
calls `orderOut(nil)` rather than `close()`, so window delegates won't
see it.

**Fix:** have one presenter that decides how to show the panel view,
and isolate onboarding and settings into their own presenters. And stop
reusing the same NSHostingController across two windows — make two.

### 2.9 `WindowGroup("Sticky Note", for: UUID.self)` duplicates state

**File:** `Sources/App/ClippedApp.swift:67-75`
**File:** `Sources/Views/StickyNoteView.swift`

`StickyNoteView` resolves the item by scanning
`manager.items.first { $0.id == itemID }`. If the item is removed or
trimmed by max-size policy while a sticky is open, the sticky pops to a
"Item no longer available" state and dismisses itself via
`.onChange(of: item == nil)`. That's OK-ish, but:

- No notification to the user that their sticky just vanished.
- If persistence is off and the app restarts, any UUID the system
  restored via state restoration will 404.
- Linear scan through the history on every render isn't free when the
  user has 500 items — which is the maximum you let them configure.

Consider: stickies should pin the item (holding a strong reference /
copy), not look it up by id.

### 2.10 Observability: logging exists, metrics do not

You've done the right thing with `os.Logger`, subsystem, category. But
nothing measures *frequency*. Things I'd want to know in prod:

- How often does the pasteboard poll miss changes because they came
  faster than the poll rate?
- How long does `saveHistory()` actually take on an average user's
  hardware?
- How often does `HistoryStore.load()` fall into the "corrupted file"
  path?

`Signpost` APIs are free to add, and invaluable the first time you get
a bug report that says "the app is slow."

---

## 3. Concurrency & Swift 6 nitpicks

### 3.1 `SWIFT_STRICT_CONCURRENCY: complete` with `@MainActor` on everything

You've flipped every service to `@MainActor`. That compiles cleanly, but
it's the "blanket MainActor" antipattern the concurrency skill specifically
warns against. The excuse "we're already on main" is not a design
principle.

Real concurrency hygiene says: isolate the UI-bound types (`ClipboardManager`
in its current form, the views) and let storage, network, and file I/O
run off-main. Right now:

- `HistoryStore`: disk I/O on main (see 1.3).
- `LinkMetadataFetcher`: actually does `URLSession.shared.data(for:)`
  which hops off main internally, but the type itself is `@MainActor`
  and holds the cache on main — so the cache lookup *is* main-actor
  work that could just be an `actor`.
- `MarkdownConverter`: already a free function, no actor. Good.
- `ClipboardMutationService`: `@MainActor`, operates on strings and
  URLs. No reason for main-actor isolation; pure computation.

Don't slap `@MainActor` on everything to silence the compiler. The
whole point of strict concurrency is to make isolation a *design*
decision.

### 3.2 `Sendable` conformance gaps

- `LinkMetadata` is a plain struct, should be `Sendable`. It's passed
  across actor boundaries via async return.
- `ClipboardContent` is Equatable, all payloads are value types, easy
  `Sendable`.
- `ClipboardItem` as a class would need `@unchecked Sendable` or
  `@Observable` + main-actor. Becomes moot once it's a struct.

### 3.3 Carbon event handler callback safety

**File:** `Sources/Services/HotkeyManager.swift:39-44`

```swift
let handlerBlock: EventHandlerUPP = { _, _, _ -> OSStatus in
    Task { @MainActor in
        HotkeyManager.shared.callback?()
    }
    return noErr
}
```

This is a C function pointer. `HotkeyManager.shared` is a `@MainActor`
global. Accessing `.shared.callback` from the C context is not
MainActor-isolated — you get away with it only because the `Task { @MainActor in ... }`
hops correctly before touching the callback. Acceptable, but brittle.
A comment explaining why this is safe (and what would break it) would
save a future reader ten minutes.

Better: capture the callback in the registration, store it in a
`nonisolated(unsafe)` atomic box, and avoid touching `.shared` from the
C callback at all.

### 3.4 Timer callbacks capture `self` strongly via Task closures

**File:** `Sources/Services/ClipboardManager.swift:125-130`

```swift
pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
    Task { @MainActor in
        self?.checkClipboard()
    }
}
```

`[weak self]` on the Timer closure is correct, but the enclosing Task
doesn't apply `[weak self]` — it doesn't need to because `self` is
captured via the already-weak reference inside the Timer's closure. Fine.
Worth a one-liner comment though; this is exactly the kind of subtlety
juniors get wrong.

---

## 4. Performance

### 4.1 `ClipboardManager.items` recomputes filters on every access

`filteredItems` / `filteredPinnedItems` are computed properties that do
a full filter + search pass on every access. SwiftUI calls them once per
render, but you also use them from keyboard navigation
(`allVisibleItems`), scroll proxy (`allVisibleItems`), `copySelectedItem`,
and `moveSelection`. Each of those calls does another O(n) pass over the
history.

For 500 items this is microseconds. Fine. But the `filteredItems` +
`filteredPinnedItems` pattern also means the view's `ForEach`
identities get recomputed fresh every time the collection re-filters,
which defeats the purpose of `LazyVStack`. Prefer caching:
`@Observable` computed properties are *not* memoized — compute once,
store.

### 4.2 `allVisibleItems` is rebuilt on every keystroke

**File:** `Sources/Views/ClipboardPanelView.swift:12-14`

```swift
private var allVisibleItems: [ClipboardItem] {
    manager.filteredPinnedItems + manager.filteredItems
}
```

Concatenates two arrays on every access: once per key press, once per
render, twice per selection move. Cheap individually but wasteful.

### 4.3 `recentSourceApps` is O(n) in items × pinnedItems

**File:** `Sources/Services/ClipboardManager.swift:65-74`

Used by the App Rules settings tab. Rebuilds a dictionary on every view
render. Not a hot path, but if you get there, precompute into a `Set`
kept in sync with `items`.

### 4.4 Regex compiles with `try!` vs Swift Regex literals

Nine `try! NSRegularExpression(pattern: ...)` calls. These are hot on
first call and cheap after. The `try!` is fine — these are
compile-time-constant patterns, so they can't fail at runtime.

But this is Swift 5.7+. You can use `Regex { ... }` literals or string
literal regex types, which are type-checked at compile time with no
`try!` required. Fewer footguns for the team — and type-checked capture
groups. Worth adopting on the next touch.

### 4.5 Dedup by equating `.image(Data, CGSize)` compares full image bytes

**File:** `Sources/Services/ClipboardManager.swift:191`

```swift
items.removeAll { $0.content == item.content && !$0.isPinned }
```

For images, this compares two `Data` blobs for full equality on every
copy. A 4 MB screenshot = a 4 MB memcmp. Fast but not free. For a
clipboard manager where the user hammers Cmd+C, this starts to add up.

A content hash (`SHA256` prefix on the data) stored on the item would
make dedup O(1) and also give you a persistent identity across app
restarts.

### 4.6 `ClipboardPanelView.mainPanelView` body is one massive expression

400+ line view. A single method. Multiple concerns:
top bar, search, filter, scroll view, sections, key press handlers,
onChange listeners, overlay toast. SwiftUI type-checker will eventually
complain (it already has to work hard). Worse, it's un-reviewable — no
reviewer is going to trace the full interaction graph in one method.

Split into subviews: `PanelContent`, `PanelKeyboardHandlers`,
`CopiedToastOverlay`, etc.

---

## 5. Accessibility & UX

I want to be blunt: none of these take more than 10 minutes individually
to fix, and all of them are blockers for a user with accessibility needs.

### 5.1 Icon-only buttons with no accessibility labels

Ellipsis button, quit, settings, export, close sticky, copy-in-sticky,
the eye reveal button — none of them have `.accessibilityLabel(...)`.
`Image(systemName:)` does not provide a useful label.

```swift
// Before
Button(action: { ... }) { Image(systemName: "gear") }

// After
Button("Settings", systemImage: "gear") { ... }
    .labelStyle(.iconOnly)
```

The `Label("Settings", systemImage: "gear")` form gets you VoiceOver for
free.

### 5.2 Fixed point sizes everywhere

`font(.system(size: 11))`, `.system(size: 10)`, `.system(size: 9)`,
`.system(size: 8)`. Dynamic Type does nothing. Users with reduced
vision can't make the panel readable.

Use semantic fonts: `.caption`, `.footnote`, `.callout`. If you must set
pixel sizes, combine with `.dynamicTypeSize(.xSmall ... .xxxLarge)`.

### 5.3 Ellipsis button only visible on hover

```swift
// ClipboardItemRow.swift:334
.opacity(isHovered ? 1 : 0)
```

Keyboard users cannot see it exists. VoiceOver users cannot hear it
exists. Touch users (trackpad is not hover!) cannot activate it.

Either make it always visible, or trigger it via a selection state that's
accessible from the keyboard.

### 5.4 Sensitive content reveal button has no keyboard path

**File:** `Sources/Views/Components/ClipboardItemRow.swift:250-258`

Only clickable. VoiceOver would announce "••••••••" with no way to
reveal. Add `.accessibilityAction(named: "Reveal content")`.

### 5.5 Quick menu modifier-key detection is a race

**File:** `Sources/Views/ClipboardPanelView.swift:25-30`

```swift
.onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
    if manager.openedViaHotkey { ... }
    else {
        showQuickMenu = NSEvent.modifierFlags.contains(.option)
    }
}
```

`NSEvent.modifierFlags` at notification time depends on whether the user
is still holding the key at the moment of the async notification. Works
most of the time. Fails exactly when the interaction is fastest.

Instead, read the modifier flags from the status-bar mouse click event
itself (`NSApp.currentEvent?.modifierFlags`) at the moment the user
clicks, and pass the intent into the view via the manager.

### 5.6 The "Copied" toast cuts the previous toast off

`dismissAfterCopy` unconditionally schedules `showCopiedToast = false`
after 400ms. Rapid copies stack up tasks that fight each other. Use an
`@State` token/cookie and only apply the dismissal if the token matches.

### 5.7 Settings → Screenshots wraps state changes in `DispatchQueue.main.async`

**File:** `Sources/Views/SettingsView.swift:80-113`

```swift
.onChange(of: settings.captureScreenshots) { _, enabled in
    if enabled {
        if let folder = screenshotWatcher.resolveBookmark() { ... }
        else {
            DispatchQueue.main.async {
                if let folder = screenshotWatcher.promptForFolder() { ... }
            }
        }
    }
    ...
}
```

Mixing GCD and Swift concurrency inside a SwiftUI onChange. The
`DispatchQueue.main.async` is there to avoid a "modifying state during
view update" warning. The proper fix is `Task { @MainActor in ... }` or
wiring the prompt to a separate action button so the toggle doesn't
directly trigger a modal.

---

## 6. Security, privacy, sandbox

### 6.1 App sandbox disabled

```yaml
com.apple.security.app-sandbox: false
```

Clipboard managers legitimately need broad pasteboard access; fine. But
this choice means:

- Not App Store distributable. Document this decision somewhere users
  can see.
- No automatic protection against a bug in `readClipboardItem` doing
  something bad with a crafted pasteboard payload.

At minimum, I'd reach for `com.apple.security.files.downloads.read-only`
and similar fine-grained entitlements where possible.

### 6.2 Secure mode default is OK, but the leak surface is real

Password manager items are flagged sensitive and excluded from the
persisted history (`HistoryStore.save` filters them out). Good. But:

- The `items` array still holds them in memory after the auto-expiry
  task fires 10-60 seconds later. If Clipped crashes with a core dump
  enabled, secrets are in the dump.
- `os.Logger` currently doesn't log item contents, but nothing prevents
  a future maintainer from adding `logger.debug("pasted \(item.preview)")`
  and shipping the first plaintext-password log.
- `NSPasteboard` items from apps that don't use `org.nspasteboard.ConcealedType`
  and don't have a bundle ID in `passwordManagerBundleIDs` are indexed
  normally. That includes Keychain Access (bundle ID
  `com.apple.keychainaccess`, not in your set), Safari password autofill,
  and any web-based password manager in a browser tab.

**Fix:** honor the broader [nspasteboard.org](https://nspasteboard.org)
types: `org.nspasteboard.TransientType`,
`org.nspasteboard.AutoGeneratedType`,
`org.nspasteboard.ConcealedType`, `de.petermaurer.TransientPasteboardType`.
Skip any pasteboard item advertising any of them.

### 6.3 `LinkMetadataFetcher` makes outbound requests for every copied URL

Privacy posture: "Clipboard history never leaves your device." (Your own
copy in the About section.) But the link metadata fetcher hits every
http(s) URL a user copies with a GET request that identifies their IP
address to that server. This is fine if documented — but right now the
UI claims otherwise.

At minimum, gate the fetch behind a settings toggle. "Fetch link
previews" defaulting to on is a perfectly defensible product decision —
but it must be a toggle the user can see, and the About copy needs to be
honest.

### 6.4 HTML parsing is ad-hoc and lenient

**File:** `Sources/Services/LinkMetadataFetcher.swift:79-143`

You decode the first 64 KB of the response as UTF-8 and regex-scan for
`<title>` and `<link rel="icon">`. Issues:

- `String(data: data.prefix(64000), encoding: .utf8)` returns `nil` if
  that prefix ends mid-codepoint. Whole parse fails. Use
  `NSString(data:encoding:)` which is lenient, or explicitly decode to a
  lossy ASCII fallback.
- `&#39;` is handled but not `&#x27;`, `&nbsp;`, or any other numeric
  entity. A common enough case that you should delegate to
  `NSAttributedString(data:options:documentAttributes:)` with
  `.html` document type. Slower but correct. Do it on an actor, off main.
- `parseFaviconURL` substring-matches `"icon"` but doesn't require a
  `rel` attribute equal to `"icon"` or `"shortcut icon"`. Any
  `<link ... class="some-icon" ...>` tag wins.
- No favicon caching by origin. Every URL copied from the same site
  re-downloads the same favicon.

Either do this properly or delete it and use `LPMetadataProvider` from
`LinkPresentation.framework`, which exists specifically for this use
case and respects the system's privacy rules.

### 6.5 Screenshot file reading races with screencapture

**File:** `Sources/Services/ScreenshotWatcher.swift:106-138`

Poll the directory every 1 s → compute diff → for each new filename,
`try? Data(contentsOf: fileURL)`. If the poll happens while
`screencapture` is still writing the file, you read a partial (or zero-
length) file. `NSImage(data: imageData)` then returns nil (usually) or
a malformed image (sometimes).

**Fix:** use `DispatchSource.makeFileSystemObjectSource` with the
`.write` mask (notifies only *after* write completes), or check file
mtime stability before reading (current mtime = mtime from 500 ms ago).

### 6.6 `HistoryStore` temporary file permissions

```swift
FileManager.default.createFile(
    atPath: tempURL.path,
    contents: data,
    attributes: [.posixPermissions: 0o600]
)
```

Good. The comment explaining why .atomic was replaced is also good
(race on world-readable temp files). Keep doing this.

But: `replaceItemAt` preserves the **destination's** attributes. If the
original `history.json` was ever written with `0o644`, the replaced file
is still `0o644`, even though the temp was `0o600`. You need to ensure
the original file is chmod'd once at migration time, or use
`replaceItemAt(... options: .usingNewMetadataOnly)`.

---

## 7. Edge cases the code does not handle

A grab-bag of "if a user does X, what happens." Most of these are
one-liners once identified; the harder part is identifying them. This is
the section I most want junior engineers to read, because "what edge
cases have we missed" is the difference between a 3-year and a 10-year
engineer.

1. **Pasteboard with both image and text.** Many apps (Messages, Notes,
   browsers) copy both the image and a text path/alt. You read image
   first, then text; the text is lost. Intentional?
2. **URL pasted as plain text with `mailto:`, `tel:`, `ssh:`, `file:`.**
   You only recognize `http`/`https` as URLs; everything else falls
   through to plainText. `mailto:` links at least deserve URL treatment.
3. **RTF with no plain text fallback.** `readClipboardItem` sets
   `plainText = pasteboard.string(forType: .string) ?? ""`. An empty
   fallback then breaks `StripToPlainTextMutation` which has a
   `!plainFallback.isEmpty` guard, so nothing happens — silent drop.
4. **Very large clipboard content.** No maximum size. Copying a 500 MB
   TIFF will happily push it through `NSImage(data:)`, burn RAM, and
   block main. Every clipboard manager I know of imposes a cap (1-10
   MB is typical).
5. **Strings containing null bytes.** `pasteboard.string(forType: .string)`
   will still return them; `JSONEncoder` handles them; but some downstream
   consumers don't. Fine for now, flag for later.
6. **RTF data with image attachments.** Stored as RTF bytes. Round-
   tripping back to pasteboard works. Converting to Markdown ignores
   images entirely. No warning to the user.
7. **Copied files (`public.file-url`).** Not handled at all — file
   references are dropped.
8. **Copied Finder selection (multiple file URLs).** Same — ignored.
9. **Paste into secure input field.** `simulatePaste` bails if
   `IsSecureEventInputEnabled()`. Good. But nothing tells the user why
   "Paste directly" did nothing.
10. **Paste while a password dialog is open.** Same failure mode. Same
    lack of feedback.
11. **Accessibility permission not granted.** `CGEvent.post(tap:)`
    silently fails. No prompt, no instruction, no link to System
    Settings. First-run experience: "the app is broken."
12. **User disables and re-enables clipboard monitoring rapidly.**
    Multiple `startMonitoring` calls stack? No — you have
    `guard !isMonitoring else { return }`. OK.
13. **User's clipboard contains a data URL (`data:image/png;base64,...`)**
    Treated as plain text, not image. Maybe intentional.
14. **Screenshots folder moved after app launch.** Security-scoped
    bookmark goes stale; `resolveBookmark` re-saves it. But if the user
    deletes the folder entirely, `startAccessingSecurityScopedResource`
    fails silently and the watcher is just dead.
15. **History file growing without bound when items are screenshots.**
    `trimToMaxSize` trims by item count, not by disk usage. A user with
    maxHistorySize = 500 and auto-capture enabled can easily produce a
    multi-GB history file. No warning.
16. **Duplicate screenshot in a tiny window.** If you take two screenshots
    within the same 1-second poll cycle, both are detected; if they have
    the same filename (unusual but possible after file rename), the
    second one's data clobbers the first in your diff logic.
17. **Monotonic UUID collisions in persistence.** Each `ClipboardItem`
    gets a new UUID at `init`. After a restore from disk, the persisted
    UUID is used. Dedup by `content == content` might collapse two items
    with different UUIDs — meaning the surviving item has the UUID of
    whichever one came last. Any sticky note window holding the old UUID
    is now orphaned. Probably fine in practice, but deserves a test.
18. **`DeveloperContentDetector` false positives.** JSON detector flags
    `{hello, world}` as developer content. File-path regex matches
    "ahem /usr/bin/env" in prose. Hex-string regex flags any 32+ char
    alphanumeric hex block — e.g. a git commit message that includes a
    commit hash.
19. **`DetectCodeSnippetMutation` false positives.** `braceOrSemicolonLine`
    matches any two lines ending with `)` — normal prose with two
    parenthetical remarks is now "code."
20. **`HotkeyManager.reregister` with a no-op change.** Tears down and
    rebuilds the Carbon event handler every time the settings tab is
    shown. Cheap but unnecessary.
21. **Hotkey held down.** Carbon `EventHotKey` fires once per press.
    OK, but macOS key repeat can produce multiple firings under some
    configurations — no debounce here.
22. **User launches second instance.** `HotkeyManager.register` can
    succeed once per bundle ID, so the second instance fails to register
    silently. First instance remains in charge. User sees no clipboard
    icon effect from the second instance. Consider a
    `NSRunningApplication.runningApplications(withBundleIdentifier:)`
    check on launch.
23. **Login items toggle from System Settings while app is running.**
    `launchAtLogin` property won't reflect the change — it only reads
    status at init. Either observe `SMAppService` state or re-read on
    settings tab appear.
24. **`SettingsManager.maxHistorySize` changes from 100 to 10.**
    `trimToMaxSize` isn't called until the next clipboard event.
    Intermediate state: the setting lies to the user for a few seconds.
    Trivial fix: call `trimToMaxSize` from the didSet observer.
25. **App quit during an in-flight save.** `HistoryStore.save` is
    synchronous, so this can't happen today. But when you move it off
    main (see 1.3), you need a graceful shutdown hook
    (`applicationWillTerminate`) that awaits any pending save.
26. **Dark mode / light mode swap mid-session.** Colors like
    `Color.primary.opacity(0.06)` are dynamic — good. But fixed
    `.orange` for sensitive lock is not adaptive across appearance. Use
    `Color(.systemOrange)`.
27. **Right-to-left languages.** Your `.leading` / `.trailing` usage is
    inconsistent with `.horizontal` paddings. Onboarding transitions
    use `.trailing` / `.leading` edges for move — those are RTL-aware
    only when you use `.edge(.leading)`. Worth a quick audit with
    `Locale` override.
28. **Extreme clock skew.** `timestamp = Date()` at capture vs.
    `RelativeDateTimeFormatter.localizedString(for:relativeTo:)` at
    render. Clock moves backwards → "in 3 minutes" for a historic item.
    Not a bug per se but a thing to know.
29. **Item removed while context menu is open.** The `ActionMenuTarget`
    holds a strong reference to the item, so the action fires on a
    zombie (not in `manager.items` anymore). `togglePin` on a removed
    item inserts it back into `pinnedItems` via mutation. Ghost items
    can reappear from a context menu on a deleted item.
30. **User copies the same URL twice in a row after mutation has been
    applied.** The mutated URL is in history; the new copy comes in
    with the ORIGINAL (pre-mutation) URL; dedup compares content byte-
    for-byte and doesn't match; you end up with both the cleaned and
    the dirty version in the history.

---

## 8. Test quality

The tests that exist are fine — good use of Swift Testing, good mocks,
readable intent. What's missing is more telling than what's there:

- **`checkClipboard` has zero tests.** The core behavior of the app —
  what happens when the pasteboard changes — is not tested at all.
  `NSPasteboard.general` is hard to mock, but you can wrap it in a
  protocol and inject.
- **`withMonitoringPaused` has zero tests.** Again, requires a
  pasteboard abstraction.
- **Secure mode auto-expiry has zero tests.** The `Task { try? await
  Task.sleep(...); ...}` pattern is untested. This is a security feature.
- **History store corruption → backup test exists? Not in the 77 lines
  of `HistoryStoreTests`. Verify.**
- **`copyItem` dropping fields has no test.** A test fixture that runs
  an item with `linkTitle`, `isDeveloperContent`, `mutationsApplied`
  through the pipeline and asserts they survive would have caught
  bug 2.6.
- **Mutation ordering has no test.** The fact that `DetectCodeSnippet`
  must be last for developer tagging to survive is an implicit
  invariant. Write a test that fails if anyone reorders the pipeline.
- **No tests for the filter bar, the search logic over rich text
  content, or for dedup behavior.** Each is one-liner test to write.
- **No ViewInspector / snapshot tests.** Fine — snapshot testing is a
  taste call. But given how much logic lives in views, *some* test
  coverage there would help.
- **`MockSettingsManager` does not conform to `MutationRulesProviding`**
  even though `SettingsManager` does. Tests of the mutation pipeline
  therefore can't exercise app-specific overrides. Add the conformance.

One meta-comment: `swiftlint:disable large_tuple` is a code smell the
linter is telling you about. The `makeManager` helper returning a
4-tuple `(ClipboardManager, MockHistoryStore, MockSettingsManager,
MockLinkMetadataFetcher)` is exactly the kind of thing a `TestContext`
struct fixes. Make one.

---

## 9. Style, hygiene, small stuff

- **File sizes.** `ClipboardMutationService.swift` is 506 lines and
  contains 12 types. `ClipboardPanelView.swift` is 411 lines of one
  view. `ClipboardItemRow.swift` mixes a SwiftUI view, a static helper
  for 1Password, and an `NSObject` action target. Split these.
- **Magic numbers.** `2` here and `64000` there and `500_000` over there
  and `.seconds(3)` somewhere else. Promote to named constants so the
  intent is searchable.
- **Mixed comment styles.** You have `// MARK: - Section` (good), `/// doc`
  comments (good) and plain `//` commentary (fine). Some files have a
  module doc block, some don't. Be consistent.
- **`swiftlint:disable:next force_try` × 11.** The force-try is a
  legitimate choice for compile-time regex; but every one of those
  comments should instead be a migration to Swift `Regex` literals. The
  suppression itself is fine.
- **Empty `init()` on singletons.** You have a lot of these. They
  aren't needed if the default member-init does the job.
- **`AppState.shared.clipboardManager`** accessed from inside views that
  already have the manager in environment. `ClipboardPanelView.openSettings`
  is the offender — the view already has `@Environment(SettingsManager.self)`,
  why reach back to `AppState.shared` to get it again?
- **Version string `"Clipped v1.0.0"` hardcoded** in `SettingsView`
  (line 155), but `project.yml` says `MARKETING_VERSION: "1.2.2"`.
  Read from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`.
- **`NSOpenPanel.runModal()` synchronously on main inside a SwiftUI
  onChange.** Functionally works, but runs a nested event loop inside
  view state propagation. Move to a button action.
- **Commented-out `cm.mutationService as? ClipboardMutationService`
  cast** in AppDelegate. The protocol abstraction (`any ClipboardMutating`)
  doesn't allow access to `rulesProvider`, so you downcast. That's a
  tell that the protocol is wrong. Add `rulesProvider` to the protocol,
  or set it via the initializer.
- **`final class` + `static let shared`** on `HistoryStore`,
  `LinkMetadataFetcher`, `HotkeyManager`, `StatusBarController`,
  `AppState`. Singletons are fine in a menu-bar utility, but wrapping
  them in protocols while still calling `.shared` at the call site is
  the worst of both worlds. Pick a side.

---

## 10. What I'd prioritize

If I were running this team and had two engineers for one sprint:

### Week 1 — stop the bleeding

1. Fix 1.1 (`ClipboardItem` reactivity) — this is the biggest user-visible
   correctness bug. Ship as a struct.
2. Fix 1.2 (history load race) — data loss.
3. Fix 1.3 (disk I/O on main) — every user will eventually feel this.
4. Fix 1.5 (image pasteboard type) — correctness bug.
5. Fix 1.9 (`launchAtLogin` recursion) and 1.10 (hotkey error reporting)
   — low effort, user-visible.

### Week 2 — foundations

6. Kill polling in `ScreenshotWatcher` (replace with `DispatchSource`).
7. Move `HistoryStore` to an `actor`, debounce saves, store images as
   separate files.
8. Fix mutation copy-item metadata loss (2.6) with a reliable helper or
   by moving to struct semantics.
9. Consolidate the two menu implementations (2.5) on SwiftUI.
10. Accessibility sweep (5.1–5.4). One PR, high leverage.

### Nice-to-have backlog

- Real HTML parsing or swap in `LPMetadataProvider`.
- Privacy toggle for link previews, with About copy updated.
- Honor the full nspasteboard.org transient/auto-generated/concealed
  type set.
- Value-type filters and precomputed `recentSourceApps`.
- Tests for `checkClipboard`, secure-mode auto-expiry, mutation
  ordering invariants.
- Split `ClipboardManager` into `PasteboardMonitor`, `ClipboardHistory`,
  and `ClipboardPipeline`.
- Delete `AppState.shared` and use a proper composition root.

---

## Appendix — what this review is *not* saying

To be fair to the authors: this is a working menu-bar clipboard
manager, in Swift 6 strict concurrency, with no third-party dependencies,
and a non-trivial test suite. The project structure is clean. The file
layout is sensible. The lint config is enforced. CI exists. The
mutation pipeline is a genuinely nice abstraction. `HistoryStore`'s
atomic write with restricted permissions shows someone was thinking
about security.

The critique above is about the difference between "working" and
"good." A principal engineer's job is to point at that gap. Yours, as
you read this, is to close it one bug at a time — and more importantly,
to develop the reflex of spotting problems like this in your own code
*before* someone else has to write the review.

Questions to ask yourself, going forward:

- "What happens if this runs twice?" (Re-entrancy.)
- "What happens if this runs before that?" (Ordering.)
- "What happens if this fails?" (Error propagation, user feedback.)
- "Who owns this mutable state?" (Ownership, isolation.)
- "How would I know if this was broken in production?" (Observability.)
- "What does the simplest user with a screen reader experience?" (A11y.)

If you ask those six questions about every method before you ship it,
90% of this review evaporates on the next project.
