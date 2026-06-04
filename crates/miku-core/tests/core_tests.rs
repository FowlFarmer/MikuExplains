//! Unit/integration tests for the GUI-free core. Run on any platform with
//! `cargo test -p miku-core`. No network, no GUI, no model required.

use miku_core::models::{canonical_card_type, ParsedSummary};
use miku_core::prompt::{local_inference_prompt, text_inference_hints, web_inference_prompt};
use miku_core::store::Store;

// ---------- parsing ----------

#[test]
fn parses_clean_json_with_items() {
    let raw = r#"{
        "tagline": "Photosynthesis basics",
        "primary_intent": "definition",
        "intent_confidence": "high",
        "needs_web_search": false,
        "used_web_search": false,
        "items": [
            { "type": "definition", "title": "Definition", "body": "Plants make food from light." }
        ]
    }"#;
    let parsed = ParsedSummary::parse(raw).expect("should parse");
    assert_eq!(parsed.tagline, "Photosynthesis basics");
    assert_eq!(parsed.primary_intent, "definition");
    assert_eq!(parsed.cards.len(), 1);
    assert_eq!(parsed.cards[0].card_type, "definition");
}

#[test]
fn parses_legacy_cards_key() {
    let raw = r#"{
        "tagline": "x",
        "primary_intent": "summary",
        "intent_confidence": "low",
        "needs_web_search": false,
        "used_web_search": false,
        "cards": [ { "type": "summary", "title": "S", "body": "body" } ]
    }"#;
    let parsed = ParsedSummary::parse(raw).expect("legacy cards key should parse");
    assert_eq!(parsed.cards.len(), 1);
}

#[test]
fn strips_markdown_fence_and_surrounding_prose() {
    let raw = "Here you go:\n```json\n{\"tagline\":\"t\",\"primary_intent\":\"summary\",\"intent_confidence\":\"medium\",\"needs_web_search\":false,\"used_web_search\":false,\"items\":[{\"type\":\"note\",\"title\":\"N\",\"body\":\"hi\"}]}\n```\nhope that helps";
    let parsed = ParsedSummary::parse(raw).expect("should extract JSON from fenced prose");
    assert_eq!(parsed.cards[0].body, "hi");
}

#[test]
fn drops_empty_body_cards_and_errors_when_all_empty() {
    let raw = r#"{
        "tagline": "t", "primary_intent": "summary", "intent_confidence": "medium",
        "needs_web_search": false, "used_web_search": false,
        "items": [ { "type": "note", "title": "N", "body": "   " } ]
    }"#;
    assert!(ParsedSummary::parse(raw).is_err(), "all-empty bodies -> error");
}

#[test]
fn sanitizes_tagline_to_four_ascii_words() {
    let raw = r#"{
        "tagline": "Héllo   world this is way too long!!!",
        "primary_intent": "summary", "intent_confidence": "medium",
        "needs_web_search": false, "used_web_search": false,
        "items": [ { "type": "note", "title": "N", "body": "b" } ]
    }"#;
    let parsed = ParsedSummary::parse(raw).unwrap();
    let words: Vec<&str> = parsed.tagline.split_whitespace().collect();
    assert!(words.len() <= 4, "tagline capped at 4 words, got {:?}", parsed.tagline);
}

#[test]
fn canonicalizes_card_types() {
    assert_eq!(canonical_card_type("define"), "definition");
    assert_eq!(canonical_card_type("Fact Check"), "validity");
    assert_eq!(canonical_card_type("stack_trace"), "code_help");
    assert_eq!(canonical_card_type("totally-unknown"), "note");
    assert_eq!(canonical_card_type("translation"), "translation");
}

#[test]
fn round_trips_to_items_key_for_frontend() {
    let raw = r#"{
        "tagline": "t", "primary_intent": "summary", "intent_confidence": "medium",
        "needs_web_search": false, "used_web_search": false,
        "items": [ { "type": "note", "title": "N", "body": "b" } ]
    }"#;
    let parsed = ParsedSummary::parse(raw).unwrap();
    let json = parsed.json_string();
    assert!(json.contains("\"items\""), "must serialize cards under items key");
    assert!(!json.contains("\"cards\""));
}

// ---------- prompts ----------

#[test]
fn hints_flag_short_selection_and_numbers() {
    let hints = text_inference_hints("GDP 2024");
    assert!(hints.contains("Word count: 2"));
    assert!(hints.contains("Very short selection"));
    assert!(hints.contains("Contains numbers"));
}

#[test]
fn local_prompt_embeds_text_and_hints() {
    let p = local_inference_prompt("hello world");
    assert!(p.contains("hello world"));
    assert!(p.contains("Local deterministic hints"));
    assert!(p.contains("Word count: 2"));
}

#[test]
fn web_prompt_embeds_local_json() {
    let p = web_inference_prompt("text", "{\"tagline\":\"t\"}");
    assert!(p.contains("Local pass JSON"));
    assert!(p.contains("\"tagline\":\"t\""));
}

// ---------- store ----------

#[test]
fn store_save_and_list_roundtrip() {
    let store = Store::open_in_memory().unwrap();
    let capture = store.save_capture("some highlighted text").unwrap();
    assert!(capture.id > 0);

    let raw = r#"{
        "tagline": "Test result", "primary_intent": "summary", "intent_confidence": "high",
        "needs_web_search": false, "used_web_search": true,
        "items": [ { "type": "summary", "title": "S", "body": "the summary" } ]
    }"#;
    let parsed = ParsedSummary::parse(raw).unwrap();
    let saved = store.save_summary(&parsed, &capture).unwrap();

    assert_eq!(saved.tagline, "Test result");
    assert!(saved.used_web_search);
    assert_eq!(saved.items.len(), 1);

    let list = store.list_summaries().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, saved.id);

    let loaded = store.load_summary(&saved.id).unwrap();
    assert_eq!(loaded.items[0].body, "the summary");
}

#[test]
fn store_lists_newest_first() {
    let store = Store::open_in_memory().unwrap();
    let raw = |t: &str| {
        format!(
            r#"{{"tagline":"{t}","primary_intent":"summary","intent_confidence":"low",
            "needs_web_search":false,"used_web_search":false,
            "items":[{{"type":"note","title":"N","body":"b"}}]}}"#
        )
    };
    for t in ["first", "second", "third"] {
        let cap = store.save_capture(t).unwrap();
        let parsed = ParsedSummary::parse(&raw(t)).unwrap();
        store.save_summary(&parsed, &cap).unwrap();
    }
    let list = store.list_summaries().unwrap();
    assert_eq!(list.len(), 3);
    assert_eq!(list[0].tagline, "third", "newest first");
}

#[test]
fn load_missing_summary_errors() {
    let store = Store::open_in_memory().unwrap();
    assert!(store.load_summary("999").is_err());
}
