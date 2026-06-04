# Rust + Tauri port

The Swift app is being replaced by a cross-platform Rust + Tauri v2 shell.
**Swift sources under `Sources/Denebula/` are left in place** as a reference until
the Tauri shell reaches parity and is verified on macOS. Delete them after.

## Layout

```
crates/miku-core/      GUI-free core. Builds + tests on any OS (no webkit/AppKit).
  src/models.rs        Result model + JSON parse/sanitize (port of ParsedCodexSummary).
  src/prompt.rs        Local + web inference prompts, deterministic hints.
  src/providers/       Provider trait + 3 backends: codex (CLI), api (HTTP), llama (CLI).
  src/store.rs         SQLite (bundled) capture/result store. Replaces .md/.json files.
  src/summarizer.rs    Orchestration: capture -> local pass -> optional web pass -> save.
  tests/core_tests.rs  13 unit/integration tests.
  tests/llama_e2e.rs   Real llama.cpp end-to-end test (skips if binary/model absent).
src-tauri/             Desktop shell (Tauri v2). OS glue + UI state bridge.
  src/lib.rs           Tray, global shortcut, panel window, pipeline, frontend bridge.
  src/capture.rs       Clipboard snapshot + synthetic copy + restore (enigo + arboard).
  src/config.rs        Provider selection + settings via MIKU_* env vars.
Resources/WebUI/       React UI (reused unchanged). tauri-bridge.js re-points the
                       webkit messageHandlers channel + state events at Tauri.
```

## Three LLM providers

Selected by `MIKU_PROVIDER=llama|codex|api` (default `llama`).

- **llama** (`MIKU_LLAMA_BIN`, `MIKU_LLAMA_MODEL`): local `llama-cli`. Default points
  at `~/dev/llama.cpp/build/bin/llama-cli` + the qwen3-4b gguf. Used for the E2E test.
- **codex** : local Codex CLI (`codex exec --sandbox read-only ...`). Only provider
  with a web-search verification pass. Not installed on this machine — untested here.
- **api** (`MIKU_API_BASE`, `MIKU_API_KEY`, `MIKU_API_MODEL`): OpenAI-compatible
  `/v1/chat/completions` endpoint.

## Test

```sh
cargo test -p miku-core --test core_tests          # fast, no model/network
cargo test -p miku-core --test llama_e2e -- --nocapture   # real local inference
```

Status: 13 unit tests pass; llama E2E passes against the local qwen3-4b model.

## Build / run

```sh
cargo build --workspace          # core + shell, links on Linux (webkit2gtk-4.1)
cargo run -p miku-explains        # launches the Tauri app (needs a display)
```

## What still needs macOS

Written but only verifiable on a Mac (this machine is Linux):

- **Global shortcut** registration + the press-while-open-closes-panel behavior.
- **Synthetic copy** (`Cmd+C`) + Accessibility permission. On Linux the x11rb enigo
  backend is used so the crate links without libxdo; Wayland blocks global synthetic
  input by design, so capture is a macOS/X11 path.
- **Tray / menu-bar** icon presentation and transparent panel placement.
- macOS bundle packaging (replaces `scripts/package_app.sh`).
```
