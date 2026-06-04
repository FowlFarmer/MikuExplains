//! Result data model + JSON parsing/sanitization.
//!
//! Faithful port of the Swift `ParsedCodexSummary` / `AIResultCard` contract so
//! the bundled React UI keeps working unchanged. Provider-agnostic: the same
//! parse/sanitize path is used for Codex, the HTTP API, and llama.cpp output.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResultCard {
    #[serde(rename = "type")]
    pub card_type: String,
    pub title: String,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub confidence: Option<String>,
}

/// Raw shape as it arrives from a model. `items` is preferred; legacy `cards`
/// is accepted for backward compatibility (matches the Swift decoder).
#[derive(Debug, Clone, Deserialize)]
struct RawSummary {
    #[serde(default)]
    tagline: String,
    #[serde(rename = "primary_intent", default)]
    primary_intent: String,
    #[serde(rename = "intent_confidence", default)]
    intent_confidence: String,
    #[serde(rename = "needs_web_search", default)]
    needs_web_search: bool,
    #[serde(rename = "used_web_search", default)]
    used_web_search: bool,
    #[serde(default)]
    items: Option<Vec<ResultCard>>,
    #[serde(default)]
    cards: Option<Vec<ResultCard>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ParsedSummary {
    pub tagline: String,
    #[serde(rename = "primary_intent")]
    pub primary_intent: String,
    #[serde(rename = "intent_confidence")]
    pub intent_confidence: String,
    #[serde(rename = "needs_web_search")]
    pub needs_web_search: bool,
    #[serde(rename = "used_web_search")]
    pub used_web_search: bool,
    /// Serialized back out as `items` so the React UI reads the modern key.
    #[serde(rename = "items")]
    pub cards: Vec<ResultCard>,
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("model returned an invalid result format: {0}")]
    InvalidOutput(String),
}

impl ParsedSummary {
    /// Parse raw model text (possibly fenced / surrounded by prose) into a
    /// sanitized summary. Mirrors `ParsedCodexSummary.parse` in Swift.
    pub fn parse(output: &str) -> Result<ParsedSummary, ParseError> {
        let cleaned = extract_json(output);
        let raw: RawSummary = serde_json::from_str(&cleaned)
            .map_err(|_| ParseError::InvalidOutput(cleaned.clone()))?;

        let source_cards = raw.items.or(raw.cards).unwrap_or_default();
        let cards: Vec<ResultCard> = source_cards
            .into_iter()
            .map(|c| ResultCard {
                card_type: canonical_card_type(&c.card_type),
                title: sanitize_title(&c.title, "Note"),
                body: c.body.trim().to_string(),
                confidence: c
                    .confidence
                    .map(|v| sanitize_identifier(&v, "medium")),
            })
            .filter(|c| !c.body.is_empty())
            .collect();

        if cards.is_empty() {
            return Err(ParseError::InvalidOutput(output.to_string()));
        }

        Ok(ParsedSummary {
            tagline: sanitize_tagline(&raw.tagline),
            primary_intent: sanitize_identifier(&raw.primary_intent, "summary"),
            intent_confidence: sanitize_identifier(&raw.intent_confidence, "medium"),
            needs_web_search: raw.needs_web_search,
            used_web_search: raw.used_web_search,
            cards,
        })
    }

    /// Pretty JSON with sorted keys (serde_json sorts map keys when the
    /// `preserve_order` feature is off, which is the default).
    pub fn json_string(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
}

/// Strip Markdown fences and slice from the first `{` to the last `}`.
fn extract_json(output: &str) -> String {
    let mut trimmed = output.trim().to_string();

    if trimmed.starts_with("```") {
        let lines: Vec<&str> = trimmed.lines().collect();
        let drop_last = matches!(lines.last(), Some(l) if l.trim() == "```");
        let end = if drop_last { lines.len().saturating_sub(1) } else { lines.len() };
        trimmed = lines[1..end].join("\n").trim().to_string();
    }

    match (trimmed.find('{'), trimmed.rfind('}')) {
        (Some(start), Some(end)) if end >= start => trimmed[start..=end].to_string(),
        _ => trimmed,
    }
}

/// Keep alphanumerics + whitespace, collapse to <=4 words. Fallback "AI Result".
fn sanitize_tagline(tagline: &str) -> String {
    let cleaned: String = tagline
        .chars()
        .map(|c| if c.is_alphanumeric() || c.is_whitespace() { c } else { ' ' })
        .collect();

    let words: Vec<&str> = cleaned.split_whitespace().take(4).collect();
    if words.is_empty() {
        "AI Result".to_string()
    } else {
        words.join(" ")
    }
}

/// Lowercase, keep alphanumerics + `_-`, join words with `_`. Fallback supplied.
fn sanitize_identifier(value: &str, fallback: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '_' || c == '-' || c == ' ' {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .to_lowercase();

    let joined = cleaned.split_whitespace().collect::<Vec<_>>().join("_");
    if joined.is_empty() {
        fallback.to_string()
    } else {
        joined
    }
}

fn sanitize_title(value: &str, fallback: &str) -> String {
    let cleaned = value.trim();
    if cleaned.is_empty() {
        fallback.to_string()
    } else {
        cleaned.to_string()
    }
}

/// Canonicalize a card type to the allowed catalog; unknown -> "note".
pub fn canonical_card_type(value: &str) -> String {
    let t = sanitize_identifier(value, "note");

    const ALLOWED: &[&str] = &[
        "definition",
        "translation",
        "summary",
        "core_point",
        "assumptions",
        "validity",
        "actions",
        "reply_draft",
        "code_help",
        "web_context",
        "numerical_sanity",
        "glossary",
        "contrarian",
        "note",
    ];

    if ALLOWED.contains(&t.as_str()) {
        return t;
    }

    match t.as_str() {
        "define" | "term" | "terminology" | "jargon" => "definition",
        "translate" => "translation",
        "main_point" | "thesis" | "core" => "core_point",
        "fact_check" | "verification" | "truth" | "claim_check" => "validity",
        "todo" | "checklist" | "tasks" | "action_items" => "actions",
        "reply" | "email" | "draft" => "reply_draft",
        "code" | "debug" | "stack_trace" | "error_help" => "code_help",
        "sources" | "research" | "context" => "web_context",
        "numbers" | "sanity_check" | "numerical" => "numerical_sanity",
        "skeptical" | "counterargument" | "counter" => "contrarian",
        _ => "note",
    }
    .to_string()
}
