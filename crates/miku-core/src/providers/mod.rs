//! LLM provider abstraction. Three backends:
//!   - `codex`  : local Codex CLI (sandboxed), supports a web-search pass.
//!   - `api`    : OpenAI-compatible HTTP chat-completions endpoint.
//!   - `llama`  : local llama.cpp `llama-cli` subprocess.
//!
//! Every provider takes a fully-formed prompt and returns raw model text. The
//! caller (summarizer) is responsible for parsing/sanitizing that text into a
//! `ParsedSummary`, so provider code stays free of result-format concerns.

mod api;
mod codex;
mod llama;

pub use api::{ApiConfig, ApiProvider};
pub use codex::CodexProvider;
pub use llama::{LlamaConfig, LlamaProvider};

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("provider executable not found: {0}")]
    ExecutableNotFound(String),
    #[error("failed to launch provider: {0}")]
    LaunchFailed(String),
    #[error("provider exited with status {status}: {output}")]
    Failed { status: i32, output: String },
    #[error("could not read provider output: {0}")]
    UnreadableOutput(String),
    #[error("http error: {0}")]
    Http(String),
}

pub trait Provider: Send + Sync {
    fn name(&self) -> &str;

    /// True if this provider can do a live web-search verification pass.
    fn supports_web_search(&self) -> bool {
        false
    }

    /// Run the prompt and return raw model output text.
    /// `web_search` is only honored when `supports_web_search()` is true.
    fn complete(&self, prompt: &str, web_search: bool) -> Result<String, ProviderError>;
}

/// Selects which provider the app uses.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Codex,
    Api,
    Llama,
    /// Ollama local server (OpenAI-compatible at http://localhost:11434).
    Ollama,
}
