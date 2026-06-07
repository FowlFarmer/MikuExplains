import Foundation

final class StreamingJSONResultParser {
    private var lastSnapshot: StreamingResultSnapshot?

    func snapshot(from output: String) -> StreamingResultSnapshot? {
        guard let taglineRead = Self.jsonStringValue(for: "tagline", in: output),
              taglineRead.isComplete,
              let intentRead = Self.jsonStringValue(for: "primary_intent", in: output),
              intentRead.isComplete else {
            return nil
        }

        let title = Self.cleanTaglineText(taglineRead.value)
        let intent = Self.cleanIdentifier(intentRead.value)

        let cards = Self.streamingCards(in: output)
        let snapshot = StreamingResultSnapshot(
            title: title.isEmpty ? "Miku is writing" : title,
            primaryIntent: intent.isEmpty ? "local" : intent,
            cards: cards
        )
        guard Self.snapshotsDiffer(snapshot, lastSnapshot) else {
            return nil
        }

        lastSnapshot = snapshot
        return snapshot
    }

    private static func snapshotsDiffer(
        _ lhs: StreamingResultSnapshot,
        _ rhs: StreamingResultSnapshot?
    ) -> Bool {
        guard let rhs else {
            return true
        }
        guard lhs.title == rhs.title,
              lhs.primaryIntent == rhs.primaryIntent,
              lhs.cards.count == rhs.cards.count else {
            return true
        }

        return zip(lhs.cards, rhs.cards).contains { left, right in
            left.type != right.type ||
                left.title != right.title ||
                left.body != right.body ||
                left.confidence != right.confidence
        }
    }

    private static func streamingCards(in output: String) -> [AIResultCard] {
        guard let itemsArrayText = arrayContent(for: "items", in: output, requireComplete: false) else {
            return []
        }

        let itemSegments = objectSegments(in: itemsArrayText, includeTrailingPartial: true)
        return itemSegments.compactMap(Self.streamingCard(from:))
    }

    private static func streamingCard(from objectText: String) -> AIResultCard? {
        guard let typeRead = jsonStringValue(for: "type", in: objectText),
              typeRead.isComplete,
              let titleRead = jsonStringValue(for: "title", in: objectText),
              titleRead.isComplete,
              objectText.contains(#""body""#),
              let bodyRead = jsonStringValue(for: "body", in: objectText) else {
            return nil
        }

        let type = canonicalCardType(typeRead.value)
        let title = cleanTitleText(titleRead.value)
        let body = cleanBodyText(bodyRead.value)
        guard body.isEmpty == false || bodyRead.isComplete else {
            return nil
        }

        let confidence = jsonStringValue(for: "confidence", in: objectText)
            .flatMap { $0.isComplete ? cleanConfidence($0.value) : nil }

        return AIResultCard(
            type: type,
            title: title.isEmpty ? fallbackTitle(for: type) : title,
            body: body,
            confidence: confidence
        )
    }

    private static func arrayContent(for key: String, in output: String, requireComplete: Bool) -> String? {
        guard let keyRange = output.range(of: #""\#(key)""#),
              let arrayStart = output[keyRange.upperBound...].firstIndex(of: "[") else {
            return nil
        }

        let contentStart = output.index(after: arrayStart)
        var depth = 1
        var isInString = false
        var isEscaped = false
        var index = contentStart

        while index < output.endIndex {
            let character = output[index]

            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                switch character {
                case "\"":
                    isInString = true
                case "[":
                    depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        return String(output[contentStart..<index])
                    }
                default:
                    break
                }
            }

            index = output.index(after: index)
        }

        return requireComplete ? nil : String(output[contentStart...])
    }

    private static func objectSegments(in text: String, includeTrailingPartial: Bool) -> [String] {
        var segments: [String] = []
        var objectStart: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                switch character {
                case "\"":
                    isInString = true
                case "{":
                    if depth == 0 {
                        objectStart = index
                    }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let start = objectStart {
                            segments.append(String(text[start...index]))
                            objectStart = nil
                        }
                    }
                case "]":
                    if depth == 0 {
                        return segments
                    }
                default:
                    break
                }
            }

            index = text.index(after: index)
        }

        if includeTrailingPartial, let objectStart {
            segments.append(String(text[objectStart...]))
        }
        return segments
    }

    private struct JSONStringRead {
        let value: String
        let isComplete: Bool
    }

    private static func jsonStringValue(for key: String, in text: String) -> JSONStringRead? {
        guard let keyRange = text.range(of: #""\#(key)""#),
              let colonIndex = text[keyRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }

        var index = text.index(after: colonIndex)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        guard index < text.endIndex, text[index] == "\"" else {
            return nil
        }

        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                result.append(decodedEscapedCharacter(character))
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return JSONStringRead(value: result, isComplete: true)
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }

        return JSONStringRead(value: result, isComplete: false)
    }

    private static func decodedEscapedCharacter(_ character: Character) -> Character {
        switch character {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        case "\"":
            return "\""
        case "\\":
            return "\\"
        default:
            return character
        }
    }

    private static func cleanDisplayText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func cleanTaglineText(_ value: String) -> String {
        let cleaned = cleanDisplayText(value)
        return isPlaceholderValue(cleaned) ? "" : cleaned
    }

    private static func cleanTitleText(_ value: String) -> String {
        let cleaned = cleanDisplayText(value)
        return isPlaceholderValue(cleaned) ? "" : cleaned
    }

    private static func cleanBodyText(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlaceholderValue(cleaned) ? "" : cleaned
    }

    private static func cleanIdentifier(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- ")).contains(scalar)
                ? Character(scalar)
                : " "
        }.reduce(into: "") { result, character in
            result.append(character)
        }
        .lowercased()
        .split(separator: " ")
        .joined(separator: "_")

        return cleaned
    }

    private static func cleanConfidence(_ value: String) -> String? {
        let cleaned = cleanIdentifier(value)
        switch cleaned {
        case "low", "medium", "high":
            return cleaned
        default:
            return nil
        }
    }

    private static func isPlaceholderValue(_ value: String) -> Bool {
        let identifier = cleanIdentifier(value)
        let placeholders: Set<String> = [
            "1_to_4_words",
            "one_to_four_words",
            "real_short_label",
            "actual_short_label",
            "short_label",
            "tagline",
            "best_intent",
            "primary_intent",
            "card_type",
            "item_type",
            "card_title",
            "title",
            "answer_text",
            "card_body_text",
            "body_text",
            "confidence",
            "low_medium_high",
            "optional_low_medium_high"
        ]

        return placeholders.contains(identifier)
    }

    private static func canonicalCardType(_ value: String) -> String {
        let type = cleanIdentifier(value)
        let allowedTypes: Set<String> = [
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
            "note"
        ]

        if allowedTypes.contains(type) {
            return type
        }

        switch type {
        case "define", "term", "terminology", "jargon":
            return "definition"
        case "translate":
            return "translation"
        case "main_point", "thesis", "core":
            return "core_point"
        case "fact_check", "verification", "truth", "claim_check":
            return "validity"
        case "todo", "checklist", "tasks", "action_items":
            return "actions"
        case "reply", "email", "draft":
            return "reply_draft"
        case "code", "debug", "stack_trace", "error_help":
            return "code_help"
        case "sources", "research", "context":
            return "web_context"
        case "numbers", "sanity_check", "numerical":
            return "numerical_sanity"
        case "skeptical", "counterargument", "counter":
            return "contrarian"
        default:
            return "note"
        }
    }

    private static func fallbackTitle(for type: String) -> String {
        switch type {
        case "definition":
            return "Definition"
        case "translation":
            return "Translate"
        case "summary":
            return "Summary"
        case "core_point":
            return "What matters"
        case "assumptions":
            return "Assumptions"
        case "validity":
            return "Check this"
        case "actions":
            return "Try this"
        case "reply_draft":
            return "Reply"
        case "code_help":
            return "Code help"
        case "web_context":
            return "Context"
        case "numerical_sanity":
            return "Sanity check"
        case "glossary":
            return "Glossary"
        case "contrarian":
            return "Pushback"
        default:
            return "Note"
        }
    }
}
