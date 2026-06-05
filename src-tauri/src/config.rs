//! Runtime configuration: which LLM provider to use and its settings.
//!
//! Four provider options:
//!   - Codex  : local Codex CLI (web-search capable).
//!   - Api    : OpenAI-compatible HTTP endpoint.
//!   - Llama  : local llama.cpp `llama-cli`.
//!   - Ollama : local Ollama server (http://localhost:11434, OpenAI-compatible).
//!
//! Defaults favor the local llama.cpp model on this machine so the app works
//! offline out of the box; switch via `MIKU_PROVIDER=codex|api|llama|ollama`
//! and the `MIKU_*` env vars below.

use std::path::PathBuf;

use miku_core::providers::{
    ApiConfig, ApiProvider, CodexProvider, LlamaConfig, LlamaProvider, Provider, ProviderKind,
};

#[derive(Clone)]
pub struct AppConfig {
    pub provider: ProviderKind,
    pub llama: LlamaConfig,
    pub api: ApiConfig,
    pub ollama: ApiConfig,
    /// tauri-plugin-global-shortcut accelerator string.
    pub shortcut: String,
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

impl Default for AppConfig {
    fn default() -> Self {
        let provider = match std::env::var("MIKU_PROVIDER").as_deref() {
            Ok("codex") => ProviderKind::Codex,
            Ok("api") => ProviderKind::Api,
            Ok("ollama") => ProviderKind::Ollama,
            _ => ProviderKind::Llama,
        };

        let llama = LlamaConfig {
            binary: env_path(
                "MIKU_LLAMA_BIN",
                home().join("dev/llama.cpp/build/bin/llama-cli"),
            ),
            model_path: env_path(
                "MIKU_LLAMA_MODEL",
                home().join(
                    "llama-models/qwen3-4b-router/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                ),
            ),
            context_window: 4096,
            max_tokens: 768,
            gpu_layers: 999,
            temperature: 0.2,
            extra_flags: vec![],
        };

        let api = ApiConfig {
            base_url: std::env::var("MIKU_API_BASE")
                .unwrap_or_else(|_| "https://api.openai.com".into()),
            api_key: std::env::var("MIKU_API_KEY").unwrap_or_default(),
            model: std::env::var("MIKU_API_MODEL").unwrap_or_else(|_| "gpt-4o-mini".into()),
            system_prompt: None,
            temperature: 0.2,
        };

        let ollama = ApiConfig {
            base_url: std::env::var("MIKU_OLLAMA_BASE")
                .unwrap_or_else(|_| "http://localhost:11434".into()),
            api_key: String::new(), // Ollama does not require a key.
            model: std::env::var("MIKU_OLLAMA_MODEL")
                .unwrap_or_else(|_| "llama3".into()),
            system_prompt: None,
            temperature: 0.2,
        };

        Self {
            provider,
            llama,
            api,
            ollama,
            shortcut: std::env::var("MIKU_SHORTCUT")
                .unwrap_or_else(|_| "CmdOrCtrl+Shift+Space".into()),
        }
    }
}

impl AppConfig {
    /// Construct the active provider as a trait object.
    pub fn build_provider(&self) -> Result<Box<dyn Provider>, String> {
        match self.provider {
            ProviderKind::Llama => Ok(Box::new(LlamaProvider::new(self.llama.clone()))),
            ProviderKind::Api => Ok(Box::new(ApiProvider::new(self.api.clone()))),
            ProviderKind::Ollama => Ok(Box::new(ApiProvider::new(self.ollama.clone()))),
            ProviderKind::Codex => {
                CodexProvider::locate().map(|p| Box::new(p) as Box<dyn Provider>).map_err(|e| e.to_string())
            }
        }
    }

    pub fn provider_label(&self) -> &'static str {
        match self.provider {
            ProviderKind::Llama => "llama.cpp",
            ProviderKind::Api => "api",
            ProviderKind::Ollama => "ollama",
            ProviderKind::Codex => "codex",
        }
    }
}

fn env_path(key: &str, fallback: PathBuf) -> PathBuf {
    std::env::var(key).map(PathBuf::from).unwrap_or(fallback)
}
