//! Prompt construction. Port of the Swift `localInferencePrompt` /
//! `webInferencePrompt` / `TextInferenceHints`.
//!
//! Difference from Swift: prompts embed the captured text inline instead of
//! pointing the model at a file path. Codex (sandboxed read-only CLI) read the
//! file; llama.cpp and the HTTP API take the text directly, so inlining is the
//! portable choice across all three providers.

/// Deterministic local hints derived from the captured text.
pub fn text_inference_hints(text: &str) -> String {
    let trimmed = text.trim();
    let words: Vec<&str> = trimmed.split_whitespace().collect();
    let lower = trimmed.to_lowercase();

    let mut hints = vec![
        format!("- Character count: {}", trimmed.chars().count()),
        format!("- Word count: {}", words.len()),
        format!(
            "- Contains newline: {}",
            if trimmed.contains('\n') { "yes" } else { "no" }
        ),
    ];

    if words.len() <= 5 {
        hints.push("- Very short selection: strong hint for definition, jargon unpacking, named entity context, or code syntax.".to_string());
    }
    if lower.contains("todo") || lower.contains("action item") || lower.contains("follow up") {
        hints.push("- Looks actionable: consider an actions checklist.".to_string());
    }
    if lower.contains("error")
        || lower.contains("exception")
        || lower.contains("traceback")
        || lower.contains("failed")
    {
        hints.push("- Looks like code or an error: consider code_help.".to_string());
    }
    if lower.contains('@') || lower.contains("thanks") || lower.contains("could you") {
        hints.push("- May be a message/email: consider reply_draft.".to_string());
    }
    if trimmed.chars().any(|c| c.is_ascii_digit()) {
        hints.push("- Contains numbers: consider numerical sanity or validity.".to_string());
    }

    hints.join("\n")
}

/// First-pass prompt: infer intent + smallest useful set of UI items.
pub fn local_inference_prompt(text: &str) -> String {
    let hints = text_inference_hints(text);
    format!(
        r#"Here is the highlighted text the user selected:

<selected_text>
{text}
</selected_text>

Miku Explains is a whimsical highlight-to-AI-action app. Infer what the user likely wants from the highlighted text, then return the smallest useful list of UI items.

Local deterministic hints:
{hints}

Use these item types exactly when appropriate: definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, web_context, numerical_sanity, glossary, contrarian, note.

Rules:
- Return only valid JSON. No Markdown fence.
- Always consider English as the user's preferred output language unless the selected text explicitly asks for another language.
- If the selected text is not English, treat translation into English as the likely primary intent unless another intent is clearly more useful.
- If the selected text is five words or fewer and looks like terminology, prefer a definition card.
- Each item is rendered as a separate card. Do not combine unrelated sections inside one item body.
- Do not force a summary item. Include summary only when it is genuinely useful or when intent confidence is low.
- If intent confidence is low, use primary_intent "summary" and include 2 or 3 likely helpful items.
- Prefer 1 to 3 items total.
- Use concise titles that name the action, such as "Definition", "Translate", "What matters", "Assumptions", "Check this", or "Try this".
- Set needs_web_search true only for factual claims, current events, named entities, citations, or source-backed verification where web context would materially improve the answer.
- If needs_web_search is true, still include a useful local result, but avoid pretending to verify facts from memory.
- Use regular ASCII characters in tagline, intent, type, title, and confidence.

JSON shape:
{{
  "tagline": "1 to 4 words",
  "primary_intent": "definition",
  "intent_confidence": "low|medium|high",
  "needs_web_search": false,
  "used_web_search": false,
  "items": [
    {{
      "type": "definition",
      "title": "Definition",
      "body": "Card body text.",
      "confidence": "optional low|medium|high"
    }}
  ]
}}"#
    )
}

/// Second-pass prompt used when the local pass requested web verification.
pub fn web_inference_prompt(text: &str, local_json: &str) -> String {
    format!(
        r#"Here is the highlighted text the user selected:

<selected_text>
{text}
</selected_text>

Miku Explains already ran a local inference pass and decided web search is useful. Use live web search for claim verification, citations, or current context, then return the final Miku Explains UI items.

Local pass JSON:
{local_json}

Rules:
- Return only valid JSON. No Markdown fence.
- Preserve the best local items when useful, but replace weak validity/context items with web-grounded ones.
- Include sources or source names in item bodies when web search informs the answer.
- Set needs_web_search false and used_web_search true.
- Prefer 1 to 3 items total.
- Use item types exactly from this catalog: definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, web_context, numerical_sanity, glossary, contrarian, note.
- Use regular ASCII characters in tagline, intent, type, title, and confidence.

JSON shape:
{{
  "tagline": "1 to 4 words",
  "primary_intent": "validity",
  "intent_confidence": "low|medium|high",
  "needs_web_search": false,
  "used_web_search": true,
  "items": [
    {{
      "type": "validity",
      "title": "Validity",
      "body": "Card body text with source context.",
      "confidence": "optional low|medium|high"
    }}
  ]
}}"#
    )
}
