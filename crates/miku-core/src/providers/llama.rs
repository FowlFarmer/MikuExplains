//! Local llama.cpp provider. Port of the WIL `LlamaCppProvider` (TypeScript)
//! adapted to a single blocking completion.
//!
//! Spawns `llama-cli -m <model> -p <chatml prompt> --no-display-prompt -no-cnv`
//! and captures stdout as the model output.

use std::path::PathBuf;
use std::process::Command;

use super::{Provider, ProviderError};

#[derive(Debug, Clone)]
pub struct LlamaConfig {
    /// Path to the `llama-cli` binary.
    pub binary: PathBuf,
    /// Path to the .gguf model.
    pub model_path: PathBuf,
    pub context_window: u32,
    pub max_tokens: u32,
    pub gpu_layers: u32,
    pub temperature: f32,
    /// Extra raw flags appended verbatim.
    pub extra_flags: Vec<String>,
}

impl Default for LlamaConfig {
    fn default() -> Self {
        Self {
            binary: PathBuf::from("llama-cli"),
            model_path: PathBuf::new(),
            context_window: 4096,
            max_tokens: 1024,
            gpu_layers: 999,
            temperature: 0.2,
            extra_flags: Vec::new(),
        }
    }
}

pub struct LlamaProvider {
    config: LlamaConfig,
}

impl LlamaProvider {
    pub fn new(config: LlamaConfig) -> Self {
        Self { config }
    }
}

impl Provider for LlamaProvider {
    fn name(&self) -> &str {
        "llama-cpp"
    }

    fn complete(&self, prompt: &str, _web_search: bool) -> Result<String, ProviderError> {
        let c = &self.config;
        let chatml = format_chatml(prompt);

        let mut args: Vec<String> = vec![
            "-m".into(),
            c.model_path.to_string_lossy().into_owned(),
            "-c".into(),
            c.context_window.to_string(),
            "-n".into(),
            c.max_tokens.to_string(),
            "-ngl".into(),
            c.gpu_layers.to_string(),
            "--temp".into(),
            c.temperature.to_string(),
            "-p".into(),
            chatml,
            "--no-display-prompt".into(),
            // -no-cnv: one-shot generation, not interactive conversation mode.
            "-no-cnv".into(),
        ];
        args.extend(c.extra_flags.iter().cloned());

        let output = Command::new(&c.binary)
            .args(&args)
            .output()
            .map_err(|e| ProviderError::LaunchFailed(e.to_string()))?;

        if !output.status.success() {
            return Err(ProviderError::Failed {
                status: output.status.code().unwrap_or(-1),
                output: String::from_utf8_lossy(&output.stderr).into_owned(),
            });
        }

        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        Ok(strip_eot(&text))
    }
}

/// Wrap the prompt in Qwen/ChatML so an Instruct model behaves. Matches the WIL
/// `formatPrompt` template.
fn format_chatml(user_prompt: &str) -> String {
    format!(
        "<|im_start|>system\nYou are Miku Explains. Respond with only valid JSON.<|im_end|>\n\
         <|im_start|>user\n{user_prompt}<|im_end|>\n<|im_start|>assistant\n"
    )
}

/// Strip a trailing ChatML end-of-turn token if the model emits it.
fn strip_eot(text: &str) -> String {
    text.trim()
        .trim_end_matches("<|im_end|>")
        .trim()
        .to_string()
}
