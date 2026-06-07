# Rust + Tauri Port

This repo contains an experimental Rust/Tauri v2 port alongside the current native Swift macOS app.

The current tested macOS app remains:

```text
Sources/MikuExplains/
```

The Rust/Tauri work is a cross-platform direction, not the source of truth for the shipped Swift menu bar app yet. Keep behavior parity notes explicit when moving features between the two.

## Layout

```text
crates/miku-core/      GUI-free core. Builds/tests without AppKit/WebKit/GTK.
  src/models.rs        Result model plus JSON parse/sanitize.
  src/prompt.rs        Local/web inference prompts plus deterministic hints.
  src/providers/       Provider trait plus codex, api, llama, and ollama-compatible paths.
  src/store.rs         SQLite capture/result store.
  src/summarizer.rs    Orchestration: capture -> local pass -> optional web pass -> save.
  tests/core_tests.rs  Fast tests with no model/network requirement.
  tests/llama_e2e.rs   Real llama.cpp end-to-end test, skipped unless binary/model are available.

src-tauri/             Desktop shell. OS glue plus UI state bridge.
  src/lib.rs           Tray, global shortcut, panel window, pipeline, frontend bridge.
  src/capture.rs       Clipboard snapshot plus synthetic copy/restore.
  src/config.rs        Provider selection/settings via MIKU_* environment variables.

Resources/WebUI/       Shared React UI. `tauri-bridge.js` maps the WebKit-style
                       message channel/state updates onto Tauri events.
```

## Providers

Selected by:

```text
MIKU_PROVIDER=llama|codex|api|ollama
```

Default is `llama`.

- `llama`: local `llama-cli` subprocess using `MIKU_LLAMA_BIN` and `MIKU_LLAMA_MODEL`.
- `codex`: local Codex CLI. This is the only provider with a web-search verification pass.
- `api`: OpenAI-compatible `/v1/chat/completions` endpoint using `MIKU_API_BASE`, `MIKU_API_KEY`, and `MIKU_API_MODEL`.
- `ollama`: OpenAI-compatible local Ollama endpoint using `MIKU_OLLAMA_BASE` and `MIKU_OLLAMA_MODEL`.

The Swift app is different: it uses Codex CLI or managed llama.cpp `llama-server`, and Ollama has been removed from the Swift path.

## Persistence

The Rust core stores captures and summaries in SQLite:

```text
macOS:  ~/Library/Application Support/MikuExplains/captures.db
Linux:  ~/.local/share/MikuExplains/captures.db
```

This differs from the current Swift app, which stores raw captures and JSON results as files under:

```text
~/Library/Application Support/MikuExplains/Captures/
```

## Test

```sh
cargo test -p miku-core --test core_tests
cargo test -p miku-core --test llama_e2e -- --nocapture
```

`llama_e2e` requires a local llama.cpp binary and GGUF model configured through `MIKU_LLAMA_BIN` and `MIKU_LLAMA_MODEL`.

## Build / Run

```sh
cargo build --workspace
cargo run -p miku-explains
```

The Tauri shell uses the shared `Resources/WebUI` frontend and creates a transparent always-on-top panel. Platform details still need careful verification on each OS, especially global shortcuts, synthetic copy permissions, tray/menu-bar behavior, and panel placement.

## Parity Notes

Features to keep aligned with Swift:

- Highlight -> shortcut -> clipboard copy/restore capture.
- Immediate loading panel feedback.
- Pressing the shortcut while open should not start duplicate work.
- Dynamic result cards from strict JSON.
- History/detail views in the React UI.
- Debug drawer and loading phase updates.
- Top-right panel placement.
- Miku visual theme and shared WebUI behavior.
