//! OpenAI-compatible HTTP chat-completions provider.
//!
//! Works with any `/v1/chat/completions`-style endpoint (OpenAI, OpenRouter,
//! a local llama.cpp `llama-server`, etc.). Non-streaming: the summarizer needs
//! the whole JSON body before parsing, so streaming buys nothing here.

use serde_json::json;

use super::{Provider, ProviderError};

#[derive(Debug, Clone)]
pub struct ApiConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    /// Defaults to "You are Miku Explains. Respond with only valid JSON."
    pub system_prompt: Option<String>,
    pub temperature: f32,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self {
            base_url: "https://api.openai.com".into(),
            api_key: String::new(),
            model: "gpt-4o-mini".into(),
            system_prompt: None,
            temperature: 0.2,
        }
    }
}

pub struct ApiProvider {
    config: ApiConfig,
}

impl ApiProvider {
    pub fn new(config: ApiConfig) -> Self {
        Self { config }
    }

    fn endpoint(&self) -> String {
        let base = self.config.base_url.trim_end_matches('/');
        if base.ends_with("/chat/completions") {
            base.to_string()
        } else if base.ends_with("/v1") {
            format!("{base}/chat/completions")
        } else {
            format!("{base}/v1/chat/completions")
        }
    }
}

impl Provider for ApiProvider {
    fn name(&self) -> &str {
        "api"
    }

    fn complete(&self, prompt: &str, _web_search: bool) -> Result<String, ProviderError> {
        let system = self
            .config
            .system_prompt
            .clone()
            .unwrap_or_else(|| "You are Miku Explains. Respond with only valid JSON.".into());

        let body = json!({
            "model": self.config.model,
            "temperature": self.config.temperature,
            "stream": false,
            "messages": [
                { "role": "system", "content": system },
                { "role": "user", "content": prompt },
            ],
        });

        let resp = ureq::post(&self.endpoint())
            .set("Authorization", &format!("Bearer {}", self.config.api_key))
            .set("Content-Type", "application/json")
            .send_json(body);

        let resp = match resp {
            Ok(r) => r,
            Err(ureq::Error::Status(code, r)) => {
                let txt = r.into_string().unwrap_or_default();
                return Err(ProviderError::Failed {
                    status: code as i32,
                    output: txt,
                });
            }
            Err(e) => return Err(ProviderError::Http(e.to_string())),
        };

        let parsed: serde_json::Value = resp
            .into_json()
            .map_err(|e| ProviderError::UnreadableOutput(e.to_string()))?;

        let content = parsed
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .ok_or_else(|| {
                ProviderError::UnreadableOutput(format!("unexpected response shape: {parsed}"))
            })?;

        Ok(content.to_string())
    }
}
