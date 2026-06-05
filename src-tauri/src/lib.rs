//! Miku Explains — Tauri shell.
//!
//! Replaces the Swift native host (AppKit + Carbon + WebKit). Owns the menu-bar
//! tray, global shortcut, clipboard capture, the transparent panel window, and
//! the bridge to the bundled React UI. All AI/persistence logic lives in
//! `miku-core`; this crate is the OS-glue + UI-state layer.

mod capture;
mod config;

use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager, PhysicalPosition, State, WebviewWindow,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

use config::AppConfig;
use miku_core::models::ParsedSummary;
use miku_core::prompt::{local_inference_prompt, web_inference_prompt};
use miku_core::store::{Store, SummaryRecord};

const STATE_EVENT: &str = "miku://state";
const PANEL_LABEL: &str = "panel";

/// Shared application state. Each field is independently locked so a long
/// inference (holding nothing) never blocks quick UI commands.
struct AppState {
    store: Mutex<Store>,
    config: Mutex<AppConfig>,
    ui: Mutex<UiState>,
}

#[derive(Default)]
struct UiState {
    debug_visible: bool,
    panel_visible: bool,
    /// In-memory summarization lock (replaces the Swift file lock for the
    /// running process). Blocks overlapping captures.
    busy: bool,
    loading_token: u64,
    debug: String,
}

// ---------------------------------------------------------------------------
// State emission helpers
// ---------------------------------------------------------------------------

fn emit(app: &AppHandle, partial: Value) {
    let _ = app.emit(STATE_EVENT, partial);
}

fn append_debug(app: &AppHandle, line: &str) {
    let st = app.state::<AppState>();
    let (visible, log) = {
        let mut ui = st.ui.lock().unwrap();
        if ui.debug.is_empty() {
            ui.debug = line.to_string();
        } else {
            ui.debug = format!("{}\n{}", ui.debug, line);
        }
        (ui.debug_visible, ui.debug.clone())
    };
    if visible {
        emit(app, json!({ "debug": log }));
    }
}

// ---------------------------------------------------------------------------
// Panel window placement / visibility
// ---------------------------------------------------------------------------

fn panel(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(PANEL_LABEL)
}

/// Park the panel in the top-right of the active monitor (40px right, 14px top),
/// matching the Swift overlay placement. Uses physical coordinates and the
/// monitor's own global offset, so it is correct on multi-monitor / scaled
/// layouts.
///
/// Done from the app (not a WM rule) so it runs *after* the compositor's own
/// placement (e.g. a Hyprland `center` rule) and therefore wins.
fn position_top_right(window: &WebviewWindow) {
    let monitor = match window.current_monitor() {
        Ok(Some(m)) => m,
        _ => return,
    };
    let mpos = monitor.position();
    let msize = monitor.size();
    let scale = monitor.scale_factor();
    let win = match window.outer_size() {
        Ok(s) => s,
        Err(_) => return,
    };
    let margin_right = (40.0 * scale) as i32;
    let margin_top = (14.0 * scale) as i32;
    let x = mpos.x + msize.width as i32 - win.width as i32 - margin_right;
    let y = mpos.y + margin_top;
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

fn show_panel(app: &AppHandle) {
    if let Some(w) = panel(app) {
        let _ = w.show();
        let _ = w.set_focus();
        position_top_right(&w);
        // Re-apply after the compositor finishes mapping/centering the window,
        // so app placement is the final word (e.g. defeats a Hyprland `center`
        // rule that runs after the window maps).
        let w2 = w.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(160));
            position_top_right(&w2);
        });
        app.state::<AppState>().ui.lock().unwrap().panel_visible = true;
    }
}

fn hide_panel(app: &AppHandle) {
    if let Some(w) = panel(app) {
        let _ = w.hide();
        app.state::<AppState>().ui.lock().unwrap().panel_visible = false;
    }
}

// ---------------------------------------------------------------------------
// History helpers
// ---------------------------------------------------------------------------

fn list_summaries(app: &AppHandle) -> Vec<SummaryRecord> {
    let st = app.state::<AppState>();
    let store = st.store.lock().unwrap();
    store.list_summaries().unwrap_or_default()
}

fn show_history(app: &AppHandle, debug_line: Option<&str>) {
    let summaries = list_summaries(app);
    if let Some(line) = debug_line {
        append_debug(app, line);
    }
    emit(
        app,
        json!({
            "view": "history",
            "title": "Miku Explains",
            "subtitle": "",
            "shortcutError": "",
            "summaries": summaries,
        }),
    );
}

// ---------------------------------------------------------------------------
// Capture + summarize pipeline
// ---------------------------------------------------------------------------

/// Triggered by the global shortcut or the tray "Explain Selection" item.
fn trigger_capture(app: &AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut ui = st.ui.lock().unwrap();
        if ui.busy {
            drop(ui);
            emit(
                app,
                json!({ "view": "message", "title": "Busy",
                        "items": [{ "type": "note", "title": "Busy",
                        "body": "Already summarizing. Wait for the current one to finish." }] }),
            );
            return;
        }
        if ui.panel_visible {
            // Pressing the shortcut while open closes the panel (Swift parity).
            ui.panel_visible = false;
            drop(ui);
            hide_panel(app);
            return;
        }
        ui.busy = true;
        ui.debug.clear();
    }

    show_panel(app);
    emit(
        app,
        json!({
            "view": "loading",
            "title": "Summarizing",
            "subtitle": "",
            "loadingPhase": "local",
            "status": "thinking",
        }),
    );

    let app = app.clone();
    std::thread::spawn(move || {
        let outcome = run_pipeline(&app);
        app.state::<AppState>().ui.lock().unwrap().busy = false;

        match outcome {
            Ok(Some(record)) => {
                let token = {
                    let st = app.state::<AppState>();
                    let mut ui = st.ui.lock().unwrap();
                    ui.loading_token += 1;
                    ui.loading_token
                };
                emit(
                    &app,
                    json!({
                        "view": "result",
                        "title": record.tagline,
                        "subtitle": "",
                        "status": record.primary_intent,
                        "items": record.items,
                        "loadingCompleteToken": token,
                    }),
                );
            }
            Ok(None) => {
                show_history(&app, Some("No copied text found. Showing past results."));
            }
            Err(e) => {
                append_debug(&app, &format!("Pipeline failed: {e}"));
                emit(
                    &app,
                    json!({
                        "view": "message",
                        "title": "Hmm",
                        "items": [{ "type": "note", "title": "Could not explain",
                                    "body": e }],
                    }),
                );
            }
        }
    });
}

/// Returns Ok(None) when no text was captured (caller shows history).
fn run_pipeline(app: &AppHandle) -> Result<Option<SummaryRecord>, String> {
    let text = match capture::grab_selection() {
        Some(t) => t,
        None => return Ok(None),
    };
    append_debug(app, &format!("Captured {} chars", text.chars().count()));

    let cfg = { app.state::<AppState>().config.lock().unwrap().clone() };
    append_debug(app, &format!("Provider: {}", cfg.provider_label()));
    let provider = cfg.build_provider()?;

    let capture_rec = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store.save_capture(&text).map_err(|e| e.to_string())?
    };

    let local_raw = provider
        .complete(&local_inference_prompt(&text), false)
        .map_err(|e| e.to_string())?;
    let local = ParsedSummary::parse(&local_raw).map_err(|e| e.to_string())?;

    let final_summary = if local.needs_web_search && provider.supports_web_search() {
        emit(app, json!({ "loadingPhase": "web", "status": "web" }));
        append_debug(app, "Entering web search verification pass...");
        let web_raw = provider
            .complete(&web_inference_prompt(&text, &local.json_string()), true)
            .map_err(|e| e.to_string())?;
        ParsedSummary::parse(&web_raw).map_err(|e| e.to_string())?
    } else {
        local
    };

    let record = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store
            .save_summary(&final_summary, &capture_rec)
            .map_err(|e| e.to_string())?
    };
    Ok(Some(record))
}

// ---------------------------------------------------------------------------
// Frontend -> backend bridge (single command, dispatched on `type`)
// ---------------------------------------------------------------------------

#[tauri::command]
fn panel_event(app: AppHandle, state: State<AppState>, payload: Value) {
    let kind = payload.get("type").and_then(|v| v.as_str()).unwrap_or("");
    eprintln!("miku: panel_event type={kind:?}");
    match kind {
        "ready" => {
            let label = state.config.lock().unwrap().shortcut.clone();
            emit(&app, json!({ "shortcutLabel": pretty_shortcut(&label) }));
            show_history(&app, None);
        }
        "close" => hide_panel(&app),
        "back" => show_history(&app, None),
        "openShortcutSettings" => {
            emit(&app, json!({ "view": "shortcut", "shortcutError": "" }));
        }
        "toggleDebug" => {
            let (visible, log) = {
                let mut ui = state.ui.lock().unwrap();
                ui.debug_visible = !ui.debug_visible;
                (ui.debug_visible, ui.debug.clone())
            };
            emit(&app, json!({ "debugVisible": visible, "debug": log }));
        }
        "selectHistory" => {
            if let Some(id) = payload.get("id").and_then(|v| v.as_str()) {
                let loaded = {
                    let store = state.store.lock().unwrap();
                    store.load_summary(id)
                };
                match loaded {
                    Ok(record) => emit(
                        &app,
                        json!({
                            "view": "result",
                            "title": record.tagline,
                            "subtitle": "",
                            "status": record.primary_intent,
                            "items": record.items,
                        }),
                    ),
                    Err(e) => emit(
                        &app,
                        json!({ "view": "message", "title": "Hmm",
                                "items": [{ "type": "note", "title": "Could not load",
                                            "body": e.to_string() }] }),
                    ),
                }
            }
        }
        "recordShortcut" => record_shortcut(&app, &payload),
        other => eprintln!("miku: unknown panel event {other:?}"),
    }
}

/// Convert a web KeyboardEvent into a tauri accelerator, re-register the global
/// shortcut, and persist it. Verified on macOS by the user later.
fn record_shortcut(app: &AppHandle, payload: &Value) {
    let code = payload.get("code").and_then(|v| v.as_str()).unwrap_or("");
    let key = match web_code_to_key(code) {
        Some(k) => k,
        None => {
            emit(app, json!({ "view": "shortcut", "shortcutError": "Unsupported key" }));
            return;
        }
    };

    let mut parts: Vec<&str> = Vec::new();
    if payload.get("metaKey").and_then(|v| v.as_bool()).unwrap_or(false) {
        parts.push("CmdOrCtrl");
    }
    if payload.get("controlKey").and_then(|v| v.as_bool()).unwrap_or(false)
        && !parts.contains(&"CmdOrCtrl")
    {
        parts.push("Ctrl");
    }
    if payload.get("altKey").and_then(|v| v.as_bool()).unwrap_or(false) {
        parts.push("Alt");
    }
    if payload.get("shiftKey").and_then(|v| v.as_bool()).unwrap_or(false) {
        parts.push("Shift");
    }
    parts.push(key);
    let accelerator = parts.join("+");

    // Unregister the previous shortcut, register the new one.
    let old = { app.state::<AppState>().config.lock().unwrap().shortcut.clone() };
    let gs = app.global_shortcut();
    let _ = gs.unregister(old.as_str());

    match gs.register(accelerator.as_str()) {
        Ok(_) => {
            app.state::<AppState>().config.lock().unwrap().shortcut = accelerator.clone();
            emit(
                app,
                json!({
                    "view": "message",
                    "shortcutLabel": pretty_shortcut(&accelerator),
                    "shortcutError": "",
                    "title": "Miku Explains",
                    "items": [{ "type": "note", "title": "Shortcut set",
                                "body": format!("New shortcut: {}", pretty_shortcut(&accelerator)) }],
                }),
            );
        }
        Err(e) => {
            let _ = gs.register(old.as_str()); // restore previous
            emit(app, json!({ "view": "shortcut", "shortcutError": e.to_string() }));
        }
    }
}

fn web_code_to_key(code: &str) -> Option<&'static str> {
    // Letters
    const LETTERS: &[(&str, &str)] = &[
        ("KeyA", "A"), ("KeyB", "B"), ("KeyC", "C"), ("KeyD", "D"), ("KeyE", "E"),
        ("KeyF", "F"), ("KeyG", "G"), ("KeyH", "H"), ("KeyI", "I"), ("KeyJ", "J"),
        ("KeyK", "K"), ("KeyL", "L"), ("KeyM", "M"), ("KeyN", "N"), ("KeyO", "O"),
        ("KeyP", "P"), ("KeyQ", "Q"), ("KeyR", "R"), ("KeyS", "S"), ("KeyT", "T"),
        ("KeyU", "U"), ("KeyV", "V"), ("KeyW", "W"), ("KeyX", "X"), ("KeyY", "Y"),
        ("KeyZ", "Z"),
    ];
    if let Some((_, k)) = LETTERS.iter().find(|(c, _)| *c == code) {
        return Some(k);
    }
    match code {
        "Space" => Some("Space"),
        "Digit0" => Some("0"), "Digit1" => Some("1"), "Digit2" => Some("2"),
        "Digit3" => Some("3"), "Digit4" => Some("4"), "Digit5" => Some("5"),
        "Digit6" => Some("6"), "Digit7" => Some("7"), "Digit8" => Some("8"),
        "Digit9" => Some("9"),
        "ArrowUp" => Some("Up"), "ArrowDown" => Some("Down"),
        "ArrowLeft" => Some("Left"), "ArrowRight" => Some("Right"),
        "Enter" => Some("Enter"), "Period" => Some("."), "Comma" => Some(","),
        _ => None,
    }
}

/// Render an accelerator with mac glyphs for the toolbar pill.
fn pretty_shortcut(accel: &str) -> String {
    accel
        .replace("CmdOrCtrl", "⌘")
        .replace("CommandOrControl", "⌘")
        .replace("Cmd", "⌘")
        .replace("Command", "⌘")
        .replace("Shift", "⇧")
        .replace("Alt", "⌥")
        .replace("Option", "⌥")
        .replace("Ctrl", "⌃")
        .replace("Control", "⌃")
        .replace('+', "")
}

// ---------------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------------

/// On macOS, synthetic keystrokes (Cmd+C for clipboard capture) require
/// Accessibility permission. This triggers the system prompt on first launch
/// if the app is not yet trusted.
#[cfg(target_os = "macos")]
fn request_accessibility_permission() {
    // Trigger the macOS Accessibility permission dialog by attempting a
    // harmless AppleScript UI action. If already trusted, this is a no-op.
    // The proper AXIsProcessTrustedWithOptions FFI is fragile without the
    // full objc2 bridge, so we use osascript as a reliable one-liner.
    let _ = std::process::Command::new("osascript")
        .args(["-e", "tell application \"System Events\" to get name of first process"])
        .output();
}

#[cfg(not(target_os = "macos"))]
fn request_accessibility_permission() {}

// ---------------------------------------------------------------------------
// App bootstrap
// ---------------------------------------------------------------------------

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // WebKitGTK on Wayland defaults to a DMA-BUF renderer + GPU compositing path
    // that breaks pointer input (hover/text-selection works, but clicks never
    // reach the page). Disabling the DMA-BUF renderer restores clicks. Must be
    // set before WebKit initializes. Linux-only; no effect on macOS/Windows.
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }

    let config = AppConfig::default();
    let shortcut = config.shortcut.clone();

    // Request macOS Accessibility permission (required for synthetic Cmd+C).
    request_accessibility_permission();

    let db_path = miku_core::default_db_path()
        .unwrap_or_else(|| std::path::PathBuf::from("captures.db"));
    if let Some(parent) = db_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let store = Store::open(&db_path).expect("open capture database");

    let app_state = AppState {
        store: Mutex::new(store),
        config: Mutex::new(config),
        ui: Mutex::new(UiState::default()),
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        trigger_capture(app);
                    }
                })
                .build(),
        )
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![panel_event])
        .setup(move |app| {
            let handle = app.handle().clone();

            // Tray menu.
            let explain = MenuItemBuilder::with_id("explain", "Explain Selection").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit Miku Explains").build(app)?;
            let menu = MenuBuilder::new(app).items(&[&explain, &quit]).build()?;

            let _tray = TrayIconBuilder::with_id("miku-tray")
                .icon(app.default_window_icon().cloned().unwrap())
                .menu(&menu)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "explain" => trigger_capture(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            // Register the global shortcut.
            if let Err(e) = handle.global_shortcut().register(shortcut.as_str()) {
                eprintln!("miku: failed to register shortcut {shortcut}: {e}");
            }

            // Linux/Wayland test hook: with MIKU_EXPLAIN_ON_START=1 the app runs
            // one capture-from-clipboard pass right after launch, so the panel +
            // pipeline can be verified without a working tray or global shortcut.
            if std::env::var("MIKU_EXPLAIN_ON_START").is_ok() {
                let h = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(900));
                    trigger_capture(&h);
                });
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Miku Explains");
}
