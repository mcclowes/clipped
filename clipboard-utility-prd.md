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

### 8. Hotkey management

Global hotkeys (used to open the clipboard panel and trigger other actions) must be registered and re-registered reliably.

**Requirements:**

- When re-registering a hotkey (e.g. after the user changes the shortcut in Settings), the existing system registration must not be released until the new registration succeeds. If the new registration fails — for example because another application already owns that key combination — the previous hotkey must be automatically restored and remain functional.
- The callback associated with a hotkey ID must be stored independently of the live system registration, so that retry attempts (including "Reset to defaults") are always possible regardless of prior registration failures.
- When a hotkey registration fails, the reason must be surfaced visibly in the Settings row for that shortcut. The error should explain that the combination is unavailable (e.g. owned by another application) and prompt the user to choose a different one. Silent failures are not acceptable.
- The in-memory registration state must always accurately reflect the live system state. A slot must never be set to nil while a system registration is still active, nor left nil after a successful registration.