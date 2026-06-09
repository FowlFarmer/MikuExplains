# Miku Explains

Miku Explains is a whimsical highlight-to-AI desktop app. Highlight text anywhere, press the global shortcut, and the app infers what kind of help you probably want: definition, translation, summary, fact/context check, actions, code help, numerical sanity, or another small set of dynamic result cards.

The currently tested app is the native macOS Swift menu bar app in `Sources/MikuExplains`. The repo also contains an experimental Rust/Tauri port; see `PORT_NOTES.md`.

## Current Swift App

The Swift app owns the macOS menu bar item, global shortcut, clipboard capture, persistence, backend routing, llama.cpp server management, and top-right panel window placement. The visible UI is a bundled React panel hosted in a transparent `WKWebView`.

Default shortcut:

```text
Command + Shift + Space
```

The shortcut is configurable from the toolbar. When the panel is closed, pressing the shortcut opens the panel immediately in a `Reading` loading state, then copies the highlighted text. When the panel is already open, pressing the shortcut checks the current selection: no selection closes the panel, the same selection closes the panel, and a different selection starts a new pipeline.

Selected-text capture uses a clipboard copy/restore path:

```text
save pasteboard -> clear pasteboard -> send Command+C -> wait up to 0.5s -> read copied text -> restore pasteboard
```

The app asks for macOS Accessibility permission so it can send the synthetic `Command+C`.

## Pipeline

Successful captures are saved as Markdown files:

```text
~/Library/Application Support/MikuExplains/Captures/yyyy-MM-dd_HH-mm-ss.md
```

The Swift pipeline then writes a tagged JSON result:

```text
capture.md -> SummaryPipeline -> backend -> [timestamp]-[tagline]-result.json
```

`summary-index.json` keeps history metadata warm and fast. Legacy `*-summary.md` result files are still readable if their matching capture file exists.

## Backends

`codex` uses the local Codex CLI and is the only Swift backend that can run the second web-search verification pass.

Hosted Google models (`google:gemma-4-26b-a4b-it`, `google:gemini-3.1-flash-lite`) use the Gemini API. Select a hosted Google model in the model dropdown to reveal the API key field. Swift stores the token directly in Keychain as a normal generic password under service `com.mikuexplains.app`, with a trusted-application ACL and no user-presence or biometric access control. When Gemma needs Keychain access, React shows a heads-up overlay first; macOS permission is requested only after the user clicks `got it`. For development, `GEMINI_API_KEY` or `GOOGLE_API_KEY` also works if no Keychain value exists.

Every non-Codex, non-`google:*` supported model tag uses the managed llama.cpp backend. Miku Explains downloads the full `llama-server` runtime into:

```text
~/Library/Application Support/MikuExplains/Models/llama-server-runtime/
```

Downloaded GGUF models live under:

```text
~/Library/Application Support/MikuExplains/Models/<model-tag>/model.gguf
```

The Swift app no longer uses Ollama.

### Result Streaming

The managed llama.cpp backend uses OpenAI-compatible streaming for local models. Hosted Gemma 4 uses Google's documented Gemma-on-Gemini `generateContent` endpoint, sets `maxOutputTokens` to 20000, omits `thinkingConfig` so thinking stays off, and parses the final response after it completes. Thought-channel parts are filtered before JSON parsing if present. Gemma requests use a configurable hard timeout (default 600s) and log endpoint, HTTP status, response bytes, network errors, returned character count, and `thoughtsTokenCount` to the debug panel. Codex also remains final-response based because it is responsible for the optional web-search verification pass.

For llama.cpp models, Swift sends `stream: true`, `max_tokens: 1024`, and `cache_prompt: true` to `/v1/chat/completions` and reads server-sent event chunks from `llama-server`. The prompt uses an ordered key contract rather than copyable placeholder JSON values, keeps the stable instruction prefix before the changing highlighted text/date/hints so llama.cpp can reuse prefix KV cache, then forces deterministic JSON key order so the app can parse useful partial structure before the full JSON is valid:

```json
{
  "tagline": "...",
  "primary_intent": "...",
  "intent_confidence": "...",
  "items": [
    {
      "id": "card_1",
      "type": "...",
      "title": "...",
      "body": "...",
      "confidence": "...",
      "tool": {
        "name": "calendar.create_event",
        "label": "Add to Calendar",
        "params": {
          "title": "Event title",
          "start": "2026-06-09T15:00:00-04:00",
          "end": "2026-06-09T16:00:00-04:00",
          "notes": "Optional notes"
        }
      }
    }
  ]
}
```

For local llama.cpp models, the result panel opens as soon as a complete `tagline` and `primary_intent` have streamed in. The streaming parser then reads the single `items` array directly: when an item has complete `type` and `title` fields and its `body` string starts, that card appears and its body updates as more tokens arrive. While there is no parseable card body yet, React shows the shared `Thinking.` / `Thinking..` / `Thinking...` status line in the result body. Hosted Gemma waits on the final `generateContent` response and does not use the thinking status line. History and disk persistence prefer the final complete JSON, but if llama.cpp stops mid-JSON after cards have streamed, Swift saves those partial cards with a cutoff note instead of replacing the result with an instruction-failure card.

Tool payloads are optional. The first supported accept buttons are `calendar.create_event` and `reminders.create_reminder`; React shows a button on the card, and Swift executes the tool through EventKit only after the user clicks. The prompt includes the current local date/time/timezone so vague dates like "Tuesday" can resolve to the next future occurrence.

Weak local models sometimes print a pseudo tool call in the card body instead of emitting a separate `tool` object. Swift salvages simple `calendar.create_event params: {...}` and `reminders.create_reminder params: {...}` bodies into real tool payloads, ignores null params, and replaces the raw call text with a readable card body.

## UI

The panel UI lives in:

```text
Resources/WebUI/index.html
Resources/WebUI/app.js
Resources/WebUI/styles.css
```

Swift sends state into React, and React sends events back through `window.webkit.messageHandlers.mikuPanel`. The panel uses Miku assets from `Resources/`, dynamic hand-drawn result cards, a history list, a debug drawer, fake loading rings, model controls, hover/click animations, and focused/unfocused styling driven by native `NSWindow` focus state.

## Build

```sh
swift build
```

## Run

For a quick SwiftPM run:

```sh
swift run MikuExplains
```

For the normal menu bar app flow:

```sh
scripts/package_app.sh
open "dist/Miku Explains.app"
```

On first run, grant Accessibility permission in System Settings.

If System Settings says Miku Explains already has Accessibility permission but the app still reports that it does not, remove Miku Explains from Accessibility, quit the app, relaunch `dist/Miku Explains.app`, and add it again. Rebuilt unsigned prototype apps can leave stale macOS privacy entries behind.

## Dev Reset

`scripts/dev.sh` is intentionally destructive. It kills the running app, stops the managed llama.cpp server, deletes:

```text
~/Library/Application Support/MikuExplains
~/Library/Application Support/Denebula
```

then resets saved defaults, deletes the Gemini API Keychain items for `com.mikuexplains.app` and legacy `app.miku-explains.prototype`, resets Accessibility permission, rebuilds, packages, and relaunches the app.

## Rust/Tauri Port

The Rust/Tauri port is in `src-tauri/` and `crates/miku-core/`. The core crate owns prompt construction, provider abstraction, result parsing, summarization orchestration, and a SQLite capture/result store. The Tauri shell owns tray, shortcut, clipboard capture, panel placement, and the React bridge.

Useful commands:

```sh
cargo test -p miku-core --test core_tests
cargo test -p miku-core --test llama_e2e -- --nocapture
cargo build --workspace
cargo run -p miku-explains
```
