# AGENTS.md

## Project Direction

- Denebula is currently scaffolded as a native macOS menu bar app built with Swift Package Manager.
- The first prototype prioritizes reliable selected-text capture with clipboard copy/restore.
- Real AI calls now run through the local Codex CLI. When text is found, Denebula saves it, asks Codex to infer the user's likely intent, and writes a tagged JSON result made of dynamic cards.

## Key Implementation Notes

- Entry point: `Sources/Denebula/main.swift`
- Menu bar and app lifecycle: `Sources/Denebula/AppDelegate.swift`
- Global shortcut: `Sources/Denebula/HotKeyController.swift`
- Selected-text capture: `Sources/Denebula/SelectedTextReader.swift`
- Capture persistence: `Sources/Denebula/CaptureStore.swift`
- Codex smart inference: `Sources/Denebula/CodexSummarizer.swift`
- Top-right result panel: `Sources/Denebula/CollapseOverlayWindowController.swift`
- Local `.app` packaging helper: `scripts/package_app.sh`

## Current UX

- The app runs as an accessory/menu bar app with no Dock icon.
- The menu bar icon is drawn programmatically as a black-hole-like status icon.
- The default shortcut is `Command + Shift + Space`.
- The app asks macOS for Accessibility permission when it launches.
- Denebula preserves the current pasteboard, clears it to avoid stale captures, sends `Command + C`, reads copied text, restores the pasteboard, and then starts the smart inference flow. If no text is copied, it opens the past results list.
- Each successful capture is saved as raw Markdown text under `~/Library/Application Support/Denebula/Captures/` using a nearest-second timestamp filename like `yyyy-MM-dd_HH-mm-ss.md`; same-second collisions receive a numeric suffix.
- After capture persistence, Denebula invokes the local Codex CLI, relying on the user's Codex app auth, to infer the user's likely intent and return strict JSON with `tagline`, `primary_intent`, confidence, web-search flags, and dynamic cards. The prompt treats English as the preferred output language and treats non-English selected text as a strong translation-to-English intent. If the local pass sets `needs_web_search`, Denebula runs a second `codex --search exec ...` pass and saves the final result as `[timestamp]-[tagline]-result.json`. Old `[timestamp]-[tagline]-summary.md` files remain readable as legacy result records.
- Summarization is guarded by a global lock: an in-memory token blocks repeated shortcuts in the running app, and `~/Library/Application Support/Denebula/summarization.lock` blocks duplicate queries across relaunches. The lock is created before clipboard capture, updated to the Codex child PID after launch, released on success/failure, and considered stale if the owner process is gone or the lock is older than six hours.
- Capture is delayed very briefly after the global hotkey so the original `Command + Shift + Space` modifiers are released before Denebula sends `Command + C`.
- Results appear in a compact top-right white rounded panel instead of a full-screen overlay.
- The result panel updates its content before ordering the window onscreen, and only fades in when first opened; in-panel page changes should not reset alpha or re-order the window.
- The detail page shows dynamic AI result cards, not the captured source text. It can show only a definition, or multiple cards such as summary, assumptions, actions, validity, web context, or code help.
- Result text uses flat black scroll containers and fixed-width text containers so text wraps vertically instead of horizontally scrolling.
- While Codex is running, the detail page shows only a fake circular progress ring using a `1 - e^-t` style curve; it eases to 100% before the summary appears.
- If Codex enters the second web-search verification pass, the loading UI switches to a `Verifying` phase with a green ring, green percent text, and `Searching web` caption.
- Validity analysis is no longer a hardcoded slot; it appears only when Codex returns a validity card.
- The main panel has a 1px grey border.
- The history list is intentionally stark: a single black custom-drawn flipped document view that paints white text rows itself and maps clicks by row position, with no AppKit button chrome, rounded bubbles, grey list styling, or visible scrollbar.
- History timestamps use a compact format like `May 19, 2:14 AM` so the time fits in the custom-drawn list column.
- The debug area is controlled by a switch and is off by default. When enabled it logs the full capture pipeline: source, character count, capture path, Codex raw output path, Codex launch, and Codex success/failure.
- The back arrow opens a history page of verified results. The history scanner lists new `*-result.json` files and legacy `*-summary.md` files whose matching pre-result `[timestamp].md` capture exists.
- Opening history is optimized with an in-memory cache warmed at launch. Refreshes scan filenames only, verify matching captures with an in-memory filename set, and load result JSON or legacy summary Markdown lazily when a history row is selected.
- Text views inside the scroll areas are explicitly sized/resizable and refreshed when content changes; do not rely on a default zero-sized `NSTextView` document view.
- The panel does not auto-hide; it stays open until the user closes it with the `×`, quits the app, or Denebula replaces it with another panel state.

## Known Limits

- Some apps may block copied selection or require focus to remain in the selected text surface.
- Full Xcode project files are not checked in; open the package in Xcode or build with `swift build`.
- `scripts/package_app.sh` creates and ad-hoc signs `dist/Denebula.app` with `LSUIElement` enabled so macOS treats it as a menu bar style app.
- macOS Accessibility permission can become stale after rebuilding unsigned prototype apps. Prefer testing through `dist/Denebula.app`; if System Settings shows permission but `AXIsProcessTrusted()` fails, remove Denebula from Accessibility, relaunch the rebuilt app, and add it again.
