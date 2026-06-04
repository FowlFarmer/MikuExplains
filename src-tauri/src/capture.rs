//! Selected-text capture via clipboard copy/restore. Port of the Swift
//! `SelectedTextReader`.
//!
//! Snapshot the clipboard, clear it, synthesize the platform copy shortcut
//! (Cmd+C on macOS, Ctrl+C elsewhere), poll for new clipboard text, then
//! restore the previous clipboard contents.
//!
//! NOTE: synthetic keystrokes require OS input permission (macOS Accessibility;
//! X11 on Linux). On Wayland global synthetic input is restricted — that path
//! is expected to be exercised on macOS.

use std::thread::sleep;
use std::time::{Duration, Instant};

use arboard::Clipboard;
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

/// Capture the current selection. Returns trimmed text, or `None` if nothing
/// was copied (e.g. no selection / app blocked the copy).
pub fn grab_selection() -> Option<String> {
    let mut clipboard = Clipboard::new().ok()?;

    // Fallback path for environments without working synthetic input
    // (e.g. Wayland/Hyprland): skip the simulated copy and explain whatever the
    // user has already copied to the clipboard. Enable with MIKU_NO_SYNTH_COPY=1.
    if std::env::var("MIKU_NO_SYNTH_COPY").is_ok() {
        return clipboard
            .get_text()
            .ok()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
    }

    let previous = clipboard.get_text().ok();

    // Clear so stale clipboard text is not mistaken for a fresh copy.
    let _ = clipboard.set_text(String::new());

    if let Err(e) = send_copy_shortcut() {
        eprintln!("miku: synthetic copy failed: {e}");
        restore(&mut clipboard, previous);
        return None;
    }

    let deadline = Instant::now() + Duration::from_millis(1000);
    let mut copied: Option<String> = None;
    while Instant::now() < deadline {
        sleep(Duration::from_millis(20));
        if let Ok(text) = clipboard.get_text() {
            if !text.is_empty() {
                copied = Some(text);
                break;
            }
        }
    }

    restore(&mut clipboard, previous);

    copied
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

fn restore(clipboard: &mut Clipboard, previous: Option<String>) {
    if let Some(prev) = previous {
        let _ = clipboard.set_text(prev);
    }
}

fn send_copy_shortcut() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;

    #[cfg(target_os = "macos")]
    let modifier = Key::Meta;
    #[cfg(not(target_os = "macos"))]
    let modifier = Key::Control;

    enigo.key(modifier, Direction::Press).map_err(|e| e.to_string())?;
    enigo
        .key(Key::Unicode('c'), Direction::Click)
        .map_err(|e| e.to_string())?;
    enigo.key(modifier, Direction::Release).map_err(|e| e.to_string())?;
    Ok(())
}
