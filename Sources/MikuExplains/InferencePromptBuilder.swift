import Foundation

enum InferencePromptBuilder {
    static func localPrompt(for record: CaptureRecord, backend: LocalInferenceBackendKind) -> String {
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
