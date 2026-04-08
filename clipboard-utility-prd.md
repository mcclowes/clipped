# PRD: Clipboard Utility for macOS

**Status:** Draft v0.1  
**Author:** Maxi  
**Target platform:** macOS 15+ (Sequoia+)

---

## Problem

macOS gives you one clipboard slot. Anything you copy replaces the last thing. That's a workflow tax most people have absorbed so completely they've forgotten it's there — until they lose something important and have to go find it again.

Windows' native clipboard history (`Win+V`) solved this years ago. macOS still hasn't. The third-party tools that exist (Paste, Clipy, Maccy) are either overbuilt, subscription-gated, or visually out of step with the platform.

---

## Goal

A lightweight, native-feeling macOS clipboard manager that fits the current platform aesthetic and gets out of the way. Nothing more.

---

## Users

Primarily knowledge workers, developers, and designers who copy and paste a lot across multiple apps. People who have already felt the pain. They don't need convincing — they need a tool that doesn't embarrass itself visually.

---

## Core features

### 1. Clipboard history

Tracks the last 10 clipboard entries. Each item stores:

- The content itself (text, image, file reference)
- Source application
- Timestamp
- Content type (plain text, rich text, image, URL, code)
- Formatting metadata where applicable

History persists across app switches but not by default across reboots (optional setting).

### 2. Bring to front

Click any item in the stack to copy it to the active clipboard. It should be re-pasteable immediately — no confirmation, no modal. The selected item moves to position 1.

Keyboard access: the panel should be navigable with arrow keys, Enter to select.

### 3. Format preservation (default on)

Rich text copies preserve their formatting — bold, italic, links, tables — unless the user explicitly strips it. This is the default because most of the time, you want what you copied.

**Toggle options per item:**

- Copy with formatting (default)
- Copy as plain text
- Copy as Markdown (converted from rich text where possible)

### 4. Image support

Images stored in the clipboard (screenshots, Figma copies, design assets) are shown as thumbnails with dimensions. Clicking copies the image back to clipboard. No editing, no conversion — just recall.

### 5. Content-type detection and filtering

The panel auto-detects:

- Plain text
- Rich/formatted text
- URLs (shown as links, with an "Open" action)
- Code snippets (shown in monospace, source app indicated)
- Images

Users can filter the panel by type. Useful when you've copied several things and know it was an image.

### 6. Pinning

Any item can be pinned. Pinned items don't scroll out of the stack — they persist above the 10-item window. A separate "Pinned" view shows all pinned items. Intended for recurring snippets — email sign-offs, code templates, etc.

### 7. Clear and remove

- Remove individual items
- Clear all (with a single undo opportunity, ~3 seconds)
- Pinned items are excluded from "Clear all" unless explicitly included

---

## Additional features

**Search** — filter the current stack by content. Simple substring match is enough for v1.

**Source attribution** — show which app the item came from. Useful when you've copied from several places and can't remember where a thing was.

**Paste and match style** — a dedicated action that strips formatting and pastes to match the destination document's style. The thing macOS buries under `Shift+Opt+Cmd+V`.

**Secure mode** — if the source app is a password manager, suppress that item from the history and zero it after a configurable timeout. This is a trust question as much as a feature.

**Link expansion** — for URLs, optionally fetch the page title and show it alongside the raw URL.

**Export / share stack** — copy multiple items at once as a merged document. Edge case, but occasionally useful for devs assembling context.

---

## UI / UX

### Trigger

Global hotkey (user-configurable, default: `⌘⇧V` or `⌘⌥V`). Shows a floating panel anchored near the cursor, or centre-screen — user preference.

When triggered via the global hotkey from another app and the menu bar is not visible (e.g. second display), the panel falls back to centre-screen or near-cursor positioning.

### Panel behaviour

- Appears on invocation, disappears on selection or click-outside or `Esc`
- Should not steal focus from the current app if possible
- Pin-to-visible option for persistent use

### Visual design

Liquid Glass (macOS 15 style). The panel should look like it belongs in the same family as Spotlight, Control Centre, and the new system alerts. Translucent frosted-glass background, subtle material blurring through, no hard borders.

Specific requirements:

- `NSVisualEffectView` with `.hudWindow` or `.popover` material
- Rounded corners consistent with system popover radius (~20pt)
- System font (`SF Pro`) throughout
- Support both light and dark appearance automatically
- No custom window chrome — borderless panel only
- Hover states use subtle highlight, not color changes
- Active/selected item uses system accent color at low opacity

Implementation should be SwiftUI or AppKit — not Electron.

---

## Menu bar

The app lives exclusively in the menu bar. No Dock presence, no app switcher entry.

### Icon

A simple stack or clipboard glyph, 18×18pt, that works in both light and dark menu bars. Should indicate state where possible — e.g. subtle fill change when the stack has content.

### Left-click behaviour

Opens the panel anchored flush below the menu bar icon, aligned to its right edge. Consistent with how system menu bar extras behave (Control Centre, Battery, etc.). Clicking the icon again while the panel is open closes it (toggle).

### Right-click / secondary click

Shows a minimal context menu:

- Preferences
- Clear History
- Quit

Keeps the primary flow clean.

### `LSUIElement`

Set `LSUIElement = YES` in `Info.plist`. Pure menu bar extra — no Dock icon, no app switcher presence.

### Onboarding

First launch should display a brief callout pointing to the menu bar icon. With no Dock presence, there's nothing else to orient the user.

---

## Technical considerations

### Stack

- **Language:** Swift
- **UI:** SwiftUI (preferred) or AppKit
- **Distribution:** Mac App Store or direct download (notarized)
- **Clipboard access:** `NSPasteboard` polling or `NSPasteboard.changeCount` monitoring
- **Storage:** Local SQLite or Core Data for history persistence

### Permissions

The app needs clipboard read access. On macOS 14+, apps are prompted when they access the pasteboard — this needs clear in-app explanation to avoid alarming users.

Images should be stored efficiently — thumbnails generated on write, originals only held for the session unless pinned.

### Privacy

No data leaves the device. Ever. This should be stated clearly in the app and marketing. Clipboard contents are sensitive.

Sensitive content detection (passwords, keys): heuristic only in v1 — flag items from known password managers by bundle ID.

---

## Out of scope for v1

- Sync across devices
- Clipboard sharing between users
- OCR on image items
- Cloud backup
- Browser extension
- Windows / Linux

---

## Open questions

1. Should history persist across reboots by default, or opt-in? (Privacy-first suggests opt-in.)
2. What's the right default history size? 10 is enough for most sessions; is there a reason to go higher?
3. Should the panel be toggleable via menu bar icon click (open/close), or only closable via `Esc` and click-outside?
4. How do we handle large items — a 20MB image paste, for example? Cap size per item?
5. Is Markdown conversion (from rich text) worth the complexity in v1, or should that be v2?

---

## Success criteria

- Invocation to paste in under 2 seconds
- No perceptible clipboard lag or monitoring overhead
- Passes App Store review on first submission (no private APIs)
- Positive reception from devs and designers in initial user testing
