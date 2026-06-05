# AGENTS.md

## Project Direction

- Miku Explains still includes the legacy native macOS Swift menu bar app built with Swift Package Manager. The Swift package/target/executable path now uses `MikuExplains` internally.
- The first prototype prioritizes reliable selected-text capture with clipboard copy/restore.
- Real AI calls now run through the local Codex CLI. When text is found, Miku Explains saves it, asks Codex to infer the user's likely intent, and writes a tagged JSON result made of dynamic UI items.

## Key Implementation Notes

- Entry point: `Sources/MikuExplains/main.swift`
- Menu bar and app lifecycle: `Sources/MikuExplains/AppDelegate.swift`
- Global shortcut: `Sources/MikuExplains/HotKeyController.swift`
- Selected-text capture: `Sources/MikuExplains/SelectedTextReader.swift`
- Capture persistence: `Sources/MikuExplains/CaptureStore.swift`
- Codex smart inference: `Sources/MikuExplains/CodexSummarizer.swift`
- Top-right result panel native WebKit host: `Sources/MikuExplains/CollapseOverlayWindowController.swift`
- Bundled React panel UI: `Resources/WebUI/index.html`, `Resources/WebUI/app.js`, `Resources/WebUI/styles.css`
- Local `.app` packaging helper: `scripts/package_app.sh`

## Current UX

- The app runs as an accessory/menu bar app with no Dock icon.
- The app is branded as `Miku Explains`, uses `Resources/miku_crop.png` as a rounded-square menu bar icon, uses `Resources/AppIcon.icns` as the bundle app icon generated from that same crop, and renders `Resources/miku.png` as a large transparent sticker in the React UI. The borderless window includes transparent top-left overhang space so the sticker can sit outside the panel without clipping. Content must stay inside the card/header layout so text never draws over the sticker.
- The React panel was rebuilt from first principles after the AppKit UI migration. Treat `Resources/WebUI/app.js` and `Resources/WebUI/styles.css` as the source of truth for all visible UI: fixed transparent stage, floating sticker, imperfect paper shell, masthead, state body, hand-drawn item cards, history rows, fake loading meter, and debug drawer.
- The Miku sticker wiggles when React enters the history list, enters a result/detail view, or receives a loading completion token. The animation is implemented by remounting the sticker with a changing React key and applying the `miku-wiggle` CSS keyframes.
- The default shortcut is `Command + Shift + Space`, displayed in the React toolbar as `shortcut: ⌘⇧Space`. Clicking that toolbar button opens an in-panel shortcut recorder page; successful captures update the Carbon global hotkey immediately and persist the shortcut in `UserDefaults` under `MikuExplainsShortcut`.
- Pressing the global shortcut while the panel is already visible first checks the current selected text with the clipboard capture path: if nothing is selected, the panel closes; if the selected text matches the last captured text, the panel closes; if the selected text is different, Miku Explains starts a fresh pipeline for the new selection. Pressing the menu bar `Explain Selection` item still starts capture directly.
- The app asks macOS for Accessibility permission when it launches.
- Miku Explains preserves the current pasteboard, clears it to avoid stale captures, sends `Command + C`, reads copied text, restores the pasteboard, and then starts the smart inference flow. If no text is copied, it opens the past results list.
- Each successful capture is saved as raw Markdown text under `~/Library/Application Support/MikuExplains/Captures/` using a nearest-second timestamp filename like `yyyy-MM-dd_HH-mm-ss.md`; same-second collisions receive a numeric suffix.
- After capture persistence, Miku Explains invokes the local Codex CLI, relying on the user's Codex app auth, to infer the user's likely intent and return strict JSON with `tagline`, `primary_intent`, confidence, web-search flags, and an `items` array. Each item has `type`, `title`, `body`, and optional `confidence`. The prompt treats English as the preferred output language and treats non-English selected text as a strong translation-to-English intent. If the local pass sets `needs_web_search`, Miku Explains runs a second `codex --search exec ...` pass and saves the final result as `[timestamp]-[tagline]-result.json`. Old JSON using `cards` and old `[timestamp]-[tagline]-summary.md` files remain readable as legacy result records.
- Summarization is guarded by a global lock: an in-memory token blocks repeated shortcuts in the running app, and `~/Library/Application Support/MikuExplains/summarization.lock` blocks duplicate queries across relaunches. The lock is created before clipboard capture, updated to the Codex child PID after launch, released on success/failure, and considered stale if the owner process is gone or the lock is older than six hours.
- Capture is delayed very briefly after the global hotkey so the original `Command + Shift + Space` modifiers are released before Miku Explains sends `Command + C`.
- Results appear in a fixed-size top-right whimsical pastel React panel hosted inside a transparent `WKWebView`, instead of a full-screen overlay or hand-built AppKit controls. The panel currently uses a 570x620 transparent borderless window with a 40px right margin and smaller 14px top margin; the visible card is inset within that window to leave room for the sticker overhang.
- The `WKWebView` transparency is part of the UI contract: `drawsBackground` must be false, the web view/layers must be non-opaque, and WebKit child views are cleared after navigation finishes. If this regresses, the symptom is a white rectangular window behind the React panel.
- Avoid broad external colored shadows on the shell or sticker because they clip against the transparent WebKit window bounds and create abrupt color cutoffs. Keep pink/teal washes inside the shell or use tight, non-bleeding shadows.
- Every panel transition resets the window to a freshly computed top-right frame on the visible screen, then lays out and reapplies that frame, to prevent history-to-detail navigation from drifting into the screen edge.
- Swift owns only the native shell/window position and sends JSON state into React. React sends events back through `window.webkit.messageHandlers.mikuPanel` for `ready`, `close`, `back`, `toggleDebug`, `selectHistory`, `openShortcutSettings`, and `recordShortcut`.
- The result panel updates its React state before ordering the window onscreen, and only fades in when first opened; in-panel page changes should not reset alpha or re-order the window.
- The detail page shows dynamic AI result item cards, not the captured source text. It can show only a definition, or multiple items such as summary, assumptions, actions, validity, web context, numerical sanity, contrarian analysis, translation, or code help.
- Result items are rendered by React as separate pastel Miku note scraps inside a vertical scroll area. They should look unfinished and hand-drawn: uneven paper corners, crooked sketch outlines, tape marks, rough marker accents, slight rotations, and marker-like titles. Avoid polished SaaS cards, smooth pill accents, or clean circular rounded-rectangle borders. Card colors are selected from a small type catalog, and unknown types are canonicalized to `note`.
- While Codex is running, the detail page shows only a fake circular progress ring using a `1 - e^-t` style curve; it eases to 100% before the summary appears.
- If Codex enters the second web-search verification pass, the loading UI switches to a `Verifying` phase with a green ring, green percent text, and `Searching web` caption.
- Validity analysis is no longer a hardcoded slot; it appears only when Codex returns a validity card.
- The main panel UI should be edited in React/CSS, not AppKit. It uses a soft Miku-inspired palette: pale mint/pink gradient paper, teal ink accents, pink sketch accents, rounded/marker-like fonts, a dedicated masthead composition, and a large `miku.png` sticker illustration.
- The history list is rendered by React as simple date-plus-tagline text rows on the pastel panel, with no AppKit button chrome. Do not re-add a repeated right-side intent/result label; it crowds the scrollbar and does not communicate useful information. Keep a small top offset in the history scroll area so the large Miku sticker does not cover the first saved row.
- History timestamps use a compact format like `May 19, 2:14 AM` so the time fits in the React history row.
- The debug area is controlled by a switch and is off by default. When enabled it logs the full capture pipeline: source, character count, capture path, Codex raw output path, Codex launch, and Codex success/failure.
- The back arrow opens a history page of verified results. The history scanner lists new `*-result.json` files and legacy `*-summary.md` files whose matching pre-result `[timestamp].md` capture exists.
- Opening history is optimized with an in-memory cache warmed at launch. Refreshes scan filenames only, verify matching captures with an in-memory filename set, and load result JSON or legacy summary Markdown lazily when a history row is selected.
- Avoid rebuilding panel visuals in AppKit; the Swift panel should remain a `WKWebView` state bridge unless native OS behavior is required.
- The panel does not auto-hide; it stays open until the user closes it with the `×`, quits the app, or Miku Explains replaces it with another panel state.

## Known Limits

- Some apps may block copied selection or require focus to remain in the selected text surface.
- Full Xcode project files are not checked in; open the package in Xcode or build with `swift build`.
- `scripts/package_app.sh` creates and ad-hoc signs `dist/Miku Explains.app` with `LSUIElement` enabled so macOS treats it as a menu bar style app. It copies `Resources/miku.png`, `Resources/miku_crop.png`, `Resources/AppIcon.icns`, and `Resources/WebUI/` into `Contents/Resources`, and sets `CFBundleIconFile` to `AppIcon`.
- macOS Accessibility permission can become stale after rebuilding unsigned prototype apps. Prefer testing through `dist/Miku Explains.app`; if System Settings shows permission but `AXIsProcessTrusted()` fails, remove Miku Explains from Accessibility, relaunch the rebuilt app, and add it again.
