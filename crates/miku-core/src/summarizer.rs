//! Summarization orchestration. Port of the Swift `CodexSummarizer.summarize`
//! flow, generalized over any `Provider`:
//!
//!   1. save capture
//!   2. local inference pass
//!   3. if the model asked for web search AND the provider supports it, run a
//!      second web-grounded pass and use its result instead
//!   4. persist + return the UI-shaped summary

use crate::models::{ParseError, ParsedSummary};
use crate::prompt::{local_inference_prompt, web_inference_prompt};
use crate::providers::{Provider, ProviderError};
use crate::store::{Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum SummarizeError {
    #[error(transparent)]
    Provider(#[from] ProviderError),
    #[error(transparent)]
    Parse(#[from] ParseError),
    #[error(transparent)]
    Store(#[from] StoreError),
}

/// Progress phases, surfaced to the UI loading meter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Local,
    Web,
}

/// Run the full capture -> inference -> persist flow.
///
/// `on_phase` is invoked when each pass begins so the caller can drive the
/// loading UI (local ring, then green "verifying" ring).
pub fn summarize<P, F>(
    provider: &P,
    store: &Store,
    text: &str,
    mut on_phase: F,
) -> Result<crate::store::SummaryRecord, SummarizeError>
where
    P: Provider + ?Sized,
    F: FnMut(Phase),
{
    let capture = store.save_capture(text)?;

    on_phase(Phase::Local);
    let local_raw = provider.complete(&local_inference_prompt(text), false)?;
    let local = ParsedSummary::parse(&local_raw)?;

    let final_summary = if local.needs_web_search && provider.supports_web_search() {
        on_phase(Phase::Web);
        let web_prompt = web_inference_prompt(text, &local.json_string());
        let web_raw = provider.complete(&web_prompt, true)?;
        ParsedSummary::parse(&web_raw)?
    } else {
        local
    };

    Ok(store.save_summary(&final_summary, &capture)?)
}
