//! miku-core: GUI-free core for Miku Explains.
//!
//! Holds everything that does not depend on the desktop shell — LLM providers,
//! the SQLite capture/result store, prompt construction, result parsing, and
//! the summarization orchestration. The Tauri binary (`src-tauri`) and the
//! tests both depend on this crate. Nothing here links AppKit/WebKit/GTK, so it
//! builds and tests on any platform.

pub mod models;
pub mod prompt;
pub mod providers;
pub mod store;
pub mod summarizer;

pub use models::{ParseError, ParsedSummary, ResultCard};
pub use providers::{
    ApiConfig, ApiProvider, CodexProvider, LlamaConfig, LlamaProvider, Provider, ProviderError,
    ProviderKind,
};
pub use store::{CaptureRecord, Store, StoreError, SummaryRecord};
pub use summarizer::{summarize, Phase, SummarizeError};

/// Default on-disk location for the capture database.
/// `~/Library/Application Support/MikuExplains/captures.db` on macOS,
/// `~/.local/share/MikuExplains/captures.db` on Linux (via the `dirs` crate).
pub fn default_db_path() -> Option<std::path::PathBuf> {
    dirs::data_dir().map(|d| d.join("MikuExplains").join("captures.db"))
}
