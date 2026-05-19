# AGENTS.md

## Project Direction

- Denebula is currently scaffolded as a native macOS menu bar app built with Swift Package Manager.
- The first prototype prioritizes reliable selected-text capture with clipboard copy/restore.
- Real AI calls now run through the local Codex CLI. When text is found, Denebula saves it, asks Codex for a tagline plus full summary, and writes a tagged summary file.

## Key Implementation Notes

- Entry point: `Sources/Denebula/main.swift`
- Menu bar and app lifecycle: `Sources/Denebula/AppDelegate.swift`
- Global shortcut: `Sources/Denebula/HotKeyController.swift`
- Selected-text capture: `Sources/Denebula/SelectedTextReader.swift`
- Capture persistence: `Sources/Denebula/CaptureStore.swift`
- Codex summarization: `Sources/Denebula/CodexSummarizer.swift`
- Top-right result panel: `Sources/Denebula/CollapseOverlayWindowController.swift`
- Local `.app` packaging helper: `scripts/package_app.sh`

## Current UX

- The app runs as an accessory/menu bar app with no Dock icon.
- The menu bar icon is drawn programmatically as a black-hole-like status icon.
- The default shortcut is `Command + Shift + Space`.
- The app asks macOS for Accessibility permission when it launches.
- Denebula preserves the current pasteboard, clears it to avoid stale captures, sends `Command + C`, reads copied text, restores the pasteboard, and then starts the summary flow. If no text is copied, it opens the past summaries list.
- Each successful capture is saved as raw Markdown text under `~/Library/Application Support/Denebula/Captures/` using a nearest-second timestamp filename like `yyyy-MM-dd_HH-mm-ss.md`; same-second collisions receive a numeric suffix.
- After capture persistence, Denebula invokes the local Codex CLI, relying on the user's Codex app auth, to summarize the captured `.md` file. Codex is prompted to return `TAGLINE:`, `VALIDITY_APPLICABLE:`, optional `VALIDITY:`, and `SUMMARY:`. Denebula parses that output, omits validity from the UI/file when not applicable, sanitizes the tagline, and writes a sibling file named `[timestamp]-[tagline]-summary.md`. The current CLI invocation does not pass an approval-policy flag; it uses `codex exec --skip-git-repo-check --sandbox read-only --output-last-message`.
- Summarization is guarded by a global lock: an in-memory token blocks repeated shortcuts in the running app, and `~/Library/Application Support/Denebula/summarization.lock` blocks duplicate queries across relaunches. The lock is created before clipboard capture, updated to the Codex child PID after launch, released on success/failure, and considered stale if the owner process is gone or the lock is older than six hours.
- Capture is delayed very briefly after the global hotkey so the original `Command + Shift + Space` modifiers are released before Denebula sends `Command + C`.
- Results appear in a compact top-right white rounded panel instead of a full-screen overlay.
- The result panel updates its content before ordering the window onscreen, and only fades in when first opened; in-panel page changes should not reset alpha or re-order the window.
- The detail page shows the summary, not the captured source text.
- Summary and validity text areas use flat black scroll containers and fixed-width text containers so text wraps vertically instead of horizontally scrolling.
- While Codex is running, the detail page shows only a fake circular progress ring using a `1 - e^-t` style curve; it eases to 100% before the summary appears.
- Validity analysis, when applicable, is displayed in its own box below the summary rather than merged into the summary text area.
- The main panel has a 1px grey border.
- The history list is intentionally stark: a single black custom-drawn flipped document view that paints white text rows itself and maps clicks by row position, with no AppKit button chrome, rounded bubbles, grey list styling, or visible scrollbar.
- History timestamps use a compact format like `May 19, 2:14 AM` so the time fits in the custom-drawn list column.
- The debug area is controlled by a switch and is off by default. When enabled it logs the full capture pipeline: source, character count, capture path, Codex raw output path, Codex launch, and Codex success/failure.
- The back arrow opens a history page of verified summaries. The history scanner only lists `*-summary.md` files whose matching pre-summary `[timestamp].md` capture exists.
- Opening history is optimized with an in-memory cache warmed at launch. Refreshes scan filenames only, verify matching captures with an in-memory filename set, and load summary Markdown contents/validity lazily when a history row is selected.
- Text views inside the scroll areas are explicitly sized/resizable and refreshed when content changes; do not rely on a default zero-sized `NSTextView` document view.
- The panel does not auto-hide; it stays open until the user closes it with the `×`, quits the app, or Denebula replaces it with another panel state.

## Known Limits

- Some apps may block copied selection or require focus to remain in the selected text surface.
- Full Xcode project files are not checked in; open the package in Xcode or build with `swift build`.
- `scripts/package_app.sh` creates and ad-hoc signs `dist/Denebula.app` with `LSUIElement` enabled so macOS treats it as a menu bar style app.
- macOS Accessibility permission can become stale after rebuilding unsigned prototype apps. Prefer testing through `dist/Denebula.app`; if System Settings shows permission but `AXIsProcessTrusted()` fails, remove Denebula from Accessibility, relaunch the rebuilt app, and add it again.
