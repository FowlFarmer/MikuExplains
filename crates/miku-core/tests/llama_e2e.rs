//! End-to-end test against a real local llama.cpp model.
//!
//! Runs the full pipeline: LlamaProvider -> summarize() -> SQLite store.
//! Skips (passes) if the binary or model is not present, so it is safe on
//! machines without a local model. Override paths with env vars:
//!   MIKU_LLAMA_BIN   (default: ~/dev/llama.cpp/build/bin/llama-cli)
//!   MIKU_LLAMA_MODEL (default: ~/llama-models/qwen3-4b-router/...Q4_K_M.gguf)

use std::path::PathBuf;

use miku_core::providers::{LlamaConfig, LlamaProvider};
use miku_core::store::Store;
use miku_core::summarizer::{summarize, Phase};

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".into()))
}

fn llama_bin() -> PathBuf {
    std::env::var("MIKU_LLAMA_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join("dev/llama.cpp/build/bin/llama-cli"))
}

fn llama_model() -> PathBuf {
    std::env::var("MIKU_LLAMA_MODEL").map(PathBuf::from).unwrap_or_else(|_| {
        home().join("llama-models/qwen3-4b-router/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
    })
}

#[test]
fn llama_end_to_end_real_inference() {
    let bin = llama_bin();
    let model = llama_model();

    if !bin.exists() || !model.exists() {
        eprintln!(
            "SKIP llama_end_to_end_real_inference: missing bin ({}) or model ({})",
            bin.display(),
            model.display()
        );
        return;
    }

    let provider = LlamaProvider::new(LlamaConfig {
        binary: bin,
        model_path: model,
        context_window: 4096,
        max_tokens: 512,
        gpu_layers: 999,
        temperature: 0.2,
        extra_flags: vec![],
    });

    let store = Store::open_in_memory().expect("in-memory store");

    let mut phases = Vec::new();
    let result = summarize(
        &provider,
        &store,
        "Mitochondria are the powerhouse of the cell.",
        |p: Phase| phases.push(p),
    );

    let summary = result.expect("llama summarize should succeed and parse valid JSON");

    // The model must have produced at least one usable card and a tagline.
    assert!(!summary.tagline.is_empty(), "tagline non-empty");
    assert!(!summary.items.is_empty(), "at least one result card");
    assert!(
        !summary.items[0].body.trim().is_empty(),
        "first card body non-empty"
    );

    // Local pass always runs.
    assert!(phases.contains(&Phase::Local), "local phase fired");

    // Persisted and listable.
    let listed = store.list_summaries().expect("list");
    assert_eq!(listed.len(), 1);

    eprintln!(
        "llama E2E ok: tagline={:?} intent={:?} cards={}",
        summary.tagline,
        summary.primary_intent,
        summary.items.len()
    );
}
