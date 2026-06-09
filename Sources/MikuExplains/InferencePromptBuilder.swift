import Foundation

enum InferencePromptBuilder {
    /// Bump when hosted Gemini system instructions change so context caches refresh.
    static let geminiAPISystemPromptVersion = "2026-06-09-v1"

    static func localPrompt(for record: CaptureRecord, backend: LocalInferenceBackendKind) -> String {
        switch backend {
        case .geminiAPI:
            return geminiAPISystemInstruction() + "\n\n" + geminiAPIUserPrompt(for: record)
        case .codex, .llamaCpp:
            break
        }

        let selectedText = (try? String(contentsOf: record.captureURL, encoding: .utf8)) ?? "No text available."
        let hints = TextInferenceHints(text: selectedText).promptText
        let dateHint = currentDateHint()
        let itemTypes: String
        let backendRules: String
        let allowedTopLevelKeys: String
        let jsonShape: String
        switch backend {
        case .codex:
            itemTypes = "definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, web_context, numerical_sanity, glossary, contrarian, note"
            backendRules = "- Set needs_web_search true only when live/current/citation-backed verification would materially improve the answer; otherwise false."
            allowedTopLevelKeys = "tagline, primary_intent, intent_confidence, needs_web_search, used_web_search, and items"
            jsonShape = """
            {
              "tagline": "1 to 4 words",
              "primary_intent": "definition",
              "intent_confidence": "low|medium|high",
              "needs_web_search": false,
              "used_web_search": false,
              "items": [
                {
                  "id": "card_1",
                  "type": "definition",
                  "title": "Definition",
                  "body": "Card body text.",
                  "confidence": "medium",
                  "tool": {
                    "name": "calendar.create_event",
                    "label": "Add to Calendar",
                    "params": {
                      "title": "Event title",
                      "start": "2026-06-09T15:00:00-04:00",
                      "end": "2026-06-09T16:00:00-04:00",
                      "notes": "Optional notes"
                    }
                  }
                }
              ]
            }
            """
        case .llamaCpp:
            itemTypes = "definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, numerical_sanity, glossary, contrarian, note"
            backendRules = """
            - For streaming UI, emit object keys exactly in the JSON shape order shown below.
            - Use one array only: items. Do not emit card_headers, card_plan, cards, or any duplicate header array.
            - For every item, emit keys in this exact order: id, type, title, body, confidence, optional tool.
            - Once you start an item's body string, write the body continuously, finish that item, then start the next item.
            - The key contract below is not example content. Fill each key with your actual answer.
            - Never output literal instruction phrases from this prompt as field values.
            """
            allowedTopLevelKeys = "tagline, primary_intent, intent_confidence, and items"
            jsonShape = """
            Open one JSON object and emit top-level keys in this order:
            1. "tagline": an actual short label string for this highlighted text.
            2. "primary_intent": one item type name chosen from the catalog.
            3. "intent_confidence": one of "low", "medium", or "high".
            4. "items": an array of one to three card objects.

            Each item object must emit keys in this order:
            1. "id": "card_1", then "card_2" if needed.
            2. "type": one item type name chosen from the catalog.
            3. "title": a short visible card title.
            4. "body": human-readable text for that card, never raw tool JSON or params.
            5. "confidence": one of "low", "medium", or "high".
            6. Optional "tool" object only for calendar/reminder accept buttons.

            A tool object, when needed, has:
            - "name": "calendar.create_event" or "reminders.create_reminder".
            - "label": "Add to Calendar" or "Add Reminder".
            - "params": object with concrete strings for title, start/due, optional end, and optional notes.
            """
        case .geminiAPI:
            fatalError("geminiAPI prompt is built by geminiAPISystemInstruction() and geminiAPIUserPrompt(for:)")
        }

        return """
        You are a whimsical highlight-to-AI-action app. Infer what the user likely wants from the highlighted text, then return the smallest useful list of UI items.

        Use these item types exactly when appropriate: \(itemTypes).

        Rules:
        - Return only valid JSON. No Markdown fence, no preamble.
        - Always consider English as the user's preferred output language unless the selected text explicitly asks for another language.
        - If the selected text is not English, treat translation into English as the likely primary intent unless another intent is clearly more useful.
        - If the selected text is five words or fewer and looks like terminology, prefer a definition card.
        - If the selected text is longer than five words, do not choose definition unless the text explicitly asks what a term means.
        - Each item is rendered as a separate card. Do not combine unrelated sections inside one item body.
        - Do not force a summary item. Include summary only when it is genuinely useful or when intent confidence is low.
        - If intent confidence is low, use primary_intent "summary" and include 2 or 3 likely helpful items.
        - If the highlighted text contains a date, deadline, appointment, meeting, assignment, task, or follow-up, consider an actions card with one optional tool.
        - Add a tool only when the text clearly implies creating a calendar event or reminder. Never invent a tool for ordinary explanations.
        - When adding a tool, keep the card body human-readable, such as "Ready to add this to Calendar." Do not write the tool name or params in the body.
        - For vague weekdays like "Tuesday", resolve the next future occurrence after the current date unless the text explicitly says today, tomorrow, this week, or a specific date.
        - Tool dates must be concrete local ISO 8601 strings with timezone offset, such as "2026-06-09T15:00:00-04:00".
        - Calendar events use tool.name "calendar.create_event" with params title, start, optional end, optional notes.
        - Reminders use tool.name "reminders.create_reminder" with params title, optional due, optional notes.
        - Omit the tool key entirely when the card should not have an accept button.
        - Confidence must be exactly "low", "medium", or "high" if present.
        - Prefer up to 3 items total.
        - Use concise titles that name the action, such as "Definition", "Translate", "What matters", "Assumptions", "Check this", or "Try this".
        \(backendRules)
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.
        - The only top-level keys allowed are \(allowedTopLevelKeys).

        JSON output contract:
        \(jsonShape)

        Now analyze this request.

        Current date grounding:
        \(dateHint)

        Local deterministic hints:
        \(hints)

        Highlighted text:
        \(selectedText)
        """
    }

    static func geminiAPISystemInstruction() -> String {
        """
        You are a whimsical highlight-to-AI-action app. Infer what the user likely wants from the highlighted text, then return the smallest useful list of UI items.

        Use these item types exactly when appropriate: definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, numerical_sanity, glossary, contrarian, note.

        Rules:
        - Return only valid JSON. No Markdown fence, no preamble.
        - Always consider English as the user's preferred output language unless the selected text explicitly asks for another language.
        - If the selected text is not English, treat translation into English as the likely primary intent unless another intent is clearly more useful.
        - If the selected text is five words or fewer and looks like terminology, prefer a definition card.
        - If the selected text is longer than five words, do not choose definition unless the text explicitly asks what a term means.
        - Each item is rendered as a separate card. Do not combine unrelated sections inside one item body.
        - Do not force a summary item. Include summary only when it is genuinely useful or when intent confidence is low.
        - If intent confidence is low, use primary_intent "summary" and include 2 or 3 likely helpful items.
        - If the highlighted text contains a date, deadline, appointment, meeting, assignment, task, or follow-up, consider an actions card with one optional tool.
        - Add a tool only when the text clearly implies creating a calendar event or reminder. Never invent a tool for ordinary explanations.
        - When adding a tool, keep the card body human-readable, such as "Ready to add this to Calendar." Do not write the tool name or params in the body.
        - For vague weekdays like "Tuesday", resolve the next future occurrence after the current date unless the text explicitly says today, tomorrow, this week, or a specific date.
        - Tool dates must be concrete local ISO 8601 strings with timezone offset, such as "2026-06-09T15:00:00-04:00".
        - Calendar events use tool.name "calendar.create_event" with params title, start, optional end, optional notes.
        - Reminders use tool.name "reminders.create_reminder" with params title, optional due, optional notes.
        - Omit the tool key entirely when the card should not have an accept button.
        - Confidence must be exactly "low", "medium", or "high" if present.
        - Prefer up to 3 items total.
        - Use concise titles that name the action, such as "Definition", "Translate", "What matters", "Assumptions", "Check this", or "Try this".
        - This app is using a hosted Google Gemini API model.
        - Do not claim to run live web search, browser lookup, or citation retrieval.
        - Return one array only: items. Do not emit card_headers, card_plan, cards, or any duplicate header array.
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.
        - The only top-level keys allowed are tagline, primary_intent, intent_confidence, and items.

        JSON output contract:
        {
          "tagline": "Actual short label",
          "primary_intent": "summary",
          "intent_confidence": "medium",
          "items": [
            {
              "id": "card_1",
              "type": "summary",
              "title": "What matters",
              "body": "Card body text.",
              "confidence": "medium"
            }
          ]
        }

        Item type reference:
        - definition: explain a term, acronym, symbol, or short phrase.
        - translation: render non-English selected text into English, or clarify wording.
        - summary: compress longer text into the most useful takeaway.
        - core_point: isolate the single most important claim or fact.
        - assumptions: list hidden premises the reader may be making.
        - validity: sanity-check a claim, number, date, or causal statement without web lookup.
        - actions: concrete next steps, optionally with one calendar or reminder tool.
        - reply_draft: suggested response text for a message or email tone.
        - code_help: explain code, errors, APIs, or syntax in the selection.
        - numerical_sanity: check magnitudes, units, percentages, or arithmetic plausibility.
        - glossary: unpack multiple terms or jargon in one card when needed.
        - contrarian: offer a reasonable opposing view or caveat.
        - note: fallback card for low-confidence or miscellaneous guidance.

        Tool object reference:
        - calendar.create_event params: title (string), start (ISO 8601 with offset), optional end, optional notes.
        - reminders.create_reminder params: title (string), optional due (ISO 8601 with offset), optional notes.
        - Never emit pseudo tool calls in the card body. Put executable tools only in the tool object.

        Placeholder values are invalid outputs:
        - Reject using instruction examples such as "Actual short label", "What matters", "Card body text.", "card_1", or schema labels as final field values unless they truly match the selection.

        Miku Explains hosted Gemini cache key: \(geminiAPISystemPromptVersion)
        """
    }

    static func geminiAPIUserPrompt(for record: CaptureRecord) -> String {
        let selectedText = (try? String(contentsOf: record.captureURL, encoding: .utf8)) ?? "No text available."
        let hints = TextInferenceHints(text: selectedText).promptText
        let dateHint = currentDateHint()

        return """
        Now analyze this request.

        Current date grounding:
        \(dateHint)

        Local deterministic hints:
        \(hints)

        Highlighted text:
        \(selectedText)
        """
    }

    /// Static reference bundled into explicit context caches so Gemini meets minimum cache size.
    static func geminiAPICacheReferenceCorpus() -> String {
        """
        Miku Explains hosted Gemini reference corpus. This document is cached once and reused across highlight requests.

        Card selection heuristics:
        - One-word jargon in code comments usually wants definition or code_help, not summary.
        - Email greetings plus a question usually want reply_draft plus assumptions.
        - Meeting notes with dates want actions, sometimes with calendar.create_event.
        - Statistics in news text want validity or numerical_sanity.
        - Foreign language snippets want translation first unless the user asks to reply in that language.
        - Stack traces want code_help with the likely fix path, not a generic summary.
        - Legal or policy excerpts want core_point plus assumptions, not contrarian unless the text is argumentative.
        - Product marketing copy wants summary plus assumptions about audience.
        - Academic abstracts want summary plus core_point.
        - Tweets or short social posts want core_point or validity depending on factual claims.
        - Todo lists want actions without inventing calendar tools unless a specific time appears.
        - Reminder phrasing like "don't forget to" wants reminders.create_reminder when a due time exists.

        Worked JSON examples (structure only; do not copy titles or bodies verbatim):

        Example A — short term:
        Selected text: "CRISPR"
        Good output emphasizes definition with high confidence and no forced summary card.

        Example B — translation:
        Selected text: "Bonjour, est-ce que nous pouvons reporter la reunion?"
        Good output uses translation as primary_intent and may add reply_draft if tone suggests a response.

        Example C — action with tool:
        Selected text: "Team sync Tuesday at 3pm in conference room B."
        Good output resolves Tuesday to the next future weekday after the request date, emits actions, and may attach calendar.create_event with ISO start/end.

        Example D — low confidence:
        Selected text: "maybe we should rethink the rollout?"
        Good output uses primary_intent summary, intent_confidence low, and 2-3 tentative items such as assumptions, actions, and note.

        Example E — code error:
        Selected text: "TypeError: Cannot read properties of undefined (reading 'map')"
        Good output uses code_help with concrete debugging steps, not a generic definition card.

        Example F — numerical sanity:
        Selected text: "The market grew 900% last quarter according to this tweet."
        Good output uses numerical_sanity or validity and avoids claiming live fact-checking.

        Example G — contrarian:
        Selected text: "Remote work always destroys productivity."
        Good output may use contrarian with a measured caveat plus assumptions about context.

        Example H — glossary:
        Selected text: "API, OAuth, JWT, and SSO were mentioned in the RFC."
        Good output may use glossary when multiple terms need unpacking in one card.

        Example I — reply draft:
        Selected text: "Hi Sam, can you send the deck before Friday?"
        Good output uses reply_draft with a polite draft response and may include assumptions about missing context.

        Example J — reminder tool:
        Selected text: "Remind me tomorrow at 9am to submit the expense report."
        Good output uses actions with reminders.create_reminder and ISO due timestamp in local timezone.

        Invalid patterns to avoid:
        - Emitting card_headers, card_plan, cards arrays, or duplicate header lists.
        - Writing calendar.create_event or JSON params inside the visible card body.
        - Using schema placeholder strings such as "Actual short label" or "What matters" as final values.
        - Claiming live web search, browsing, or citation retrieval on hosted Gemini models.
        - Combining unrelated sections into one long body when separate cards would be clearer.
        - Forcing exactly three items when one crisp card is enough.

        Confidence guidance:
        - high: the selection clearly signals one dominant intent.
        - medium: the selection supports the chosen intent but alternative intents remain plausible.
        - low: the selection is ambiguous, extremely short without jargon, or missing crucial context.

        Title guidance:
        - Prefer action names users can scan quickly: Definition, Translate, What matters, Assumptions, Check this, Try this, Validity, Reply draft, Code help, Numbers check, Glossary, Other view.

        Tool parameter guidance:
        - Titles should be concise event/reminder names derived from the selection.
        - Start/due timestamps must include timezone offsets and reflect the grounded current date provided in each live request.
        - Notes are optional and should only repeat useful context not already in the title.

        Output discipline:
        - Return one JSON object only.
        - No markdown fences, no commentary outside JSON.
        - ASCII characters in tagline, intent, type, title, and confidence fields.
        - Up to three items unless low confidence genuinely needs broader coverage.
        - Omit tool entirely when no accept button should appear.

        Cache corpus version: \(geminiAPISystemPromptVersion)
        """
    }

    static func webPrompt(for record: CaptureRecord, localResult: ParsedCodexSummary) -> String {
        let localJSON = (try? localResult.jsonString()) ?? ""
        return """
        Read the Markdown file at this path:
        \(record.captureURL.path)

        Miku Explains already ran a local inference pass and decided web search is useful. Use live web search for claim verification, citations, or current context, then return the final Miku Explains UI items.

        Local pass JSON:
        \(localJSON)

        Rules:
        - Return only valid JSON. No Markdown fence.
        - Preserve the best local items when useful, but replace weak validity/context items with web-grounded ones.
        - Include sources or source names in item bodies when web search informs the answer.
        - Set needs_web_search false and used_web_search true.
        - Prefer 1 to 3 items total.
        - Use item types exactly from this catalog: definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, web_context, numerical_sanity, glossary, contrarian, note.
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.

        JSON shape:
        {
          "tagline": "1 to 4 words",
          "primary_intent": "validity",
          "intent_confidence": "low|medium|high",
          "needs_web_search": false,
          "used_web_search": true,
          "items": [
            {
              "type": "validity",
              "title": "Validity",
              "body": "Card body text with source context.",
              "confidence": "optional low|medium|high"
            }
          ]
        }
        """
    }
}

private func currentDateHint() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    isoFormatter.timeZone = .current

    return """
    - Current local date/time: \(formatter.string(from: now))
    - Current ISO date/time: \(isoFormatter.string(from: now))
    - Current timezone identifier: \(TimeZone.current.identifier)
    - Resolve vague future dates relative to this current date/time.
    """
}

enum LocalInferenceBackendKind {
    case codex
    case llamaCpp
    case geminiAPI
}

private struct TextInferenceHints {
    let text: String

    var promptText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
        let lowercased = trimmed.lowercased()
        var hints: [String] = [
            "- Character count: \(trimmed.count)",
            "- Word count: \(words.count)",
            "- Contains newline: \(trimmed.contains("\n") ? "yes" : "no")"
        ]

        if words.count <= 5 {
            hints.append("- Very short selection: strong hint for definition, jargon unpacking, named entity context, or code syntax.")
        }
        if lowercased.contains("todo") || lowercased.contains("action item") || lowercased.contains("follow up") {
            hints.append("- Looks actionable: consider an actions checklist.")
        }
        if lowercased.contains("error") || lowercased.contains("exception") || lowercased.contains("traceback") || lowercased.contains("failed") {
            hints.append("- Looks like code or an error: consider code_help.")
        }
        if lowercased.contains("@") || lowercased.contains("thanks") || lowercased.contains("could you") {
            hints.append("- May be a message/email: consider reply_draft.")
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("def ") || trimmed.hasPrefix("class ") {
            hints.append("- Looks like code: prefer code_help or definition.")
        }
        if trimmed.range(of: #"\d"#, options: .regularExpression) != nil {
            hints.append("- Contains numbers: consider numerical sanity or validity.")
        }

        return hints.joined(separator: "\n")
    }
}
