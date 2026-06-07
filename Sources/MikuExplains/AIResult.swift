import Foundation

struct AIResultTool: Codable {
    let name: String
    let label: String?
    let params: [String: String]

    enum CodingKeys: String, CodingKey {
        case name
        case label
        case params
    }

    init(name: String, label: String?, params: [String: String]) {
        self.name = name
        self.label = label
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
        params = try container.decodeIfPresent([String: LossyToolParam].self, forKey: .params)?
            .compactMapValues(\.stringValue) ?? [:]
    }
}

private struct LossyToolParam: Decodable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            stringValue = nil
        } else if let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            stringValue = trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        } else if let value = try? container.decode(Int.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Double.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Bool.self) {
            stringValue = value ? "true" : "false"
        } else {
            stringValue = nil
        }
    }
}

struct AIResultCard: Codable {
    let type: String
    let title: String
    let body: String
    let confidence: String?
    let tool: AIResultTool?

    enum CodingKeys: String, CodingKey {
        case type
        case title
        case body
        case confidence
        case tool
    }

    init(
        type: String,
        title: String,
        body: String,
        confidence: String?,
        tool: AIResultTool? = nil
    ) {
        self.type = type
        self.title = title
        self.body = body
        self.confidence = confidence
        self.tool = tool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "note"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Note"
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
        tool = try container.decodeIfPresent(AIResultTool.self, forKey: .tool)
    }
}

struct ParsedCodexSummary: Codable {
    let tagline: String
    let primaryIntent: String
    let intentConfidence: String
    let needsWebSearch: Bool
    let usedWebSearch: Bool
    let cards: [AIResultCard]

    enum CodingKeys: String, CodingKey {
        case tagline
        case primaryIntent = "primary_intent"
        case intentConfidence = "intent_confidence"
        case needsWebSearch = "needs_web_search"
        case usedWebSearch = "used_web_search"
        case cards
        case items
        case cardPlan = "card_plan"
        case cardHeaders = "card_headers"
    }

    init(
        tagline: String,
        primaryIntent: String,
        intentConfidence: String,
        needsWebSearch: Bool,
        usedWebSearch: Bool,
        cards: [AIResultCard]
    ) {
        self.tagline = tagline
        self.primaryIntent = primaryIntent
        self.intentConfidence = intentConfidence
        self.needsWebSearch = needsWebSearch
        self.usedWebSearch = usedWebSearch
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagline = try container.decode(String.self, forKey: .tagline)
        primaryIntent = try container.decode(String.self, forKey: .primaryIntent)
        intentConfidence = try container.decode(String.self, forKey: .intentConfidence)
        needsWebSearch = try container.decodeIfPresent(Bool.self, forKey: .needsWebSearch) ?? false
        usedWebSearch = try container.decodeIfPresent(Bool.self, forKey: .usedWebSearch) ?? false
        cards = try container.decodeIfPresent([AIResultCard].self, forKey: .items)
            ?? container.decodeIfPresent([AIResultCard].self, forKey: .cards)
            ?? container.decodeIfPresent([AIResultCard].self, forKey: .cardHeaders)
            ?? container.decodeIfPresent([AIResultCard].self, forKey: .cardPlan)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagline, forKey: .tagline)
        try container.encode(primaryIntent, forKey: .primaryIntent)
        try container.encode(intentConfidence, forKey: .intentConfidence)
        try container.encode(needsWebSearch, forKey: .needsWebSearch)
        try container.encode(usedWebSearch, forKey: .usedWebSearch)
        try container.encode(cards, forKey: .items)
    }

    static func parse(_ output: String) throws -> ParsedCodexSummary {
        let cleanedOutput = extractJSON(from: output)
        guard let data = cleanedOutput.data(using: .utf8) else {
            throw CodexSummarizerError.invalidOutput(output)
        }

        do {
            let decoded = try JSONDecoder().decode(ParsedCodexSummary.self, from: data)
            let sanitizedCards = decoded.cards
                .map { card in
                    let explicitTool = sanitizeTool(card.tool)
                    let inferredTool = inferToolFromBody(card.body)
                    let tool = explicitTool ?? inferredTool
                    return AIResultCard(
                        type: canonicalCardType(card.type),
                        title: sanitizeTitle(card.title, fallback: "Note"),
                        body: sanitizeBody(card.body, tool: tool),
                        confidence: sanitizeConfidence(card.confidence),
                        tool: tool
                    )
                }
                .filter { $0.body.isEmpty == false }

            guard sanitizedCards.isEmpty == false else {
                throw CodexSummarizerError.invalidOutput(output)
            }

            return ParsedCodexSummary(
                tagline: sanitizeTagline(decoded.tagline, fallbackCard: sanitizedCards.first),
                primaryIntent: sanitizePrimaryIntent(decoded.primaryIntent, cards: sanitizedCards),
                intentConfidence: sanitizeIdentifier(decoded.intentConfidence, fallback: "medium"),
                needsWebSearch: decoded.needsWebSearch,
                usedWebSearch: decoded.usedWebSearch,
                cards: sanitizedCards
            )
        } catch let error as CodexSummarizerError {
            throw error
        } catch {
            throw CodexSummarizerError.invalidOutput(cleanedOutput)
        }
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func extractJSON(from output: String) -> String {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            trimmed = lines
                .dropFirst()
                .dropLast(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" ? 1 : 0)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }

        return String(trimmed[start...end])
    }

    private static func sanitizeTagline(_ tagline: String, fallbackCard: AIResultCard?) -> String {
        let cleaned = tagline.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(.whitespaces).contains(scalar) ? Character(scalar) : " "
        }.reduce(into: "") { result, character in
            result.append(character)
        }

        let words = cleaned
            .split(separator: " ")
            .prefix(4)
            .map(String.init)

        let result = words.joined(separator: " ")
        if result.isEmpty || isPlaceholderValue(result) {
            let fallbackTitle = fallbackCard.map { sanitizeTitle($0.title, fallback: "") } ?? ""
            if fallbackTitle.isEmpty == false && isPlaceholderValue(fallbackTitle) == false {
                return sanitizeTagline(fallbackTitle, fallbackCard: nil)
            }
            return "AI Result"
        }

        return result
    }

    private static func sanitizeIdentifier(_ value: String, fallback: String) -> String {
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

        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func sanitizeTitle(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || isPlaceholderValue(cleaned) ? fallback : cleaned
    }

    private static func sanitizeBody(_ value: String, tool: AIResultTool? = nil) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPlaceholderValue(cleaned) {
            return ""
        }
        if let tool, looksLikeRawToolBody(cleaned) {
            return displayBody(for: tool)
        }
        return cleaned
    }

    private static func sanitizePrimaryIntent(_ value: String, cards: [AIResultCard]) -> String {
        let cleaned = sanitizeIdentifier(value, fallback: "")
        if cleaned.isEmpty || isPlaceholderIdentifier(cleaned) {
            return cards.first?.type ?? "summary"
        }

        if cleaned == "definition",
           let firstType = cards.first?.type,
           firstType != "definition" {
            return firstType
        }

        return cleaned
    }

    private static func sanitizeConfidence(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let cleaned = sanitizeIdentifier(value, fallback: "")
        switch cleaned {
        case "low", "medium", "high":
            return cleaned
        default:
            return nil
        }
    }

    private static func isPlaceholderValue(_ value: String) -> Bool {
        isPlaceholderIdentifier(sanitizeIdentifier(value, fallback: ""))
    }

    private static func isPlaceholderIdentifier(_ identifier: String) -> Bool {
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
        let type = sanitizeIdentifier(value, fallback: "note")
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

    private static func sanitizeTool(_ tool: AIResultTool?) -> AIResultTool? {
        guard let tool else {
            return nil
        }

        let name = sanitizeIdentifier(tool.name, fallback: "")
        let allowedNames: Set<String> = [
            "calendar_create_event",
            "reminders_create_reminder"
        ]
        guard allowedNames.contains(name) else {
            return nil
        }

        let normalizedName: String
        switch name {
        case "calendar_create_event":
            normalizedName = "calendar.create_event"
        case "reminders_create_reminder":
            normalizedName = "reminders.create_reminder"
        default:
            normalizedName = name
        }

        let cleanedParams = tool.params.reduce(into: [String: String]()) { result, entry in
            let key = sanitizeIdentifier(entry.key, fallback: "")
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }

        guard cleanedParams.isEmpty == false else {
            return nil
        }

        return AIResultTool(
            name: normalizedName,
            label: tool.label?.trimmingCharacters(in: .whitespacesAndNewlines),
            params: cleanedParams
        )
    }

    private static func inferToolFromBody(_ body: String) -> AIResultTool? {
        let normalizedBody = sanitizeIdentifier(body, fallback: "")
        let toolName: String
        let label: String
        if normalizedBody.contains("calendar_create_event") {
            toolName = "calendar.create_event"
            label = "Add to Calendar"
        } else if normalizedBody.contains("reminders_create_reminder") {
            toolName = "reminders.create_reminder"
            label = "Add Reminder"
        } else {
            return nil
        }

        guard let paramsObject = paramsObjectString(in: body),
              let paramsData = paramsObject.data(using: .utf8),
              let rawParams = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] else {
            return nil
        }

        let params = rawParams.reduce(into: [String: String]()) { result, entry in
            let key = sanitizeIdentifier(entry.key, fallback: "")
            guard key.isEmpty == false,
                  let value = stringValue(from: entry.value) else {
                return
            }
            result[key] = value
        }

        return sanitizeTool(AIResultTool(name: toolName, label: label, params: params))
    }

    private static func paramsObjectString(in body: String) -> String? {
        let lowercased = body.lowercased()
        let searchStart = lowercased.range(of: "params")?.upperBound ?? body.startIndex
        guard let objectStart = body[searchStart...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = objectStart

        while index < body.endIndex {
            let character = body[index]
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
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(body[objectStart...index])
                    }
                default:
                    break
                }
            }
            index = body.index(after: index)
        }

        return nil
    }

    private static func stringValue(from value: Any) -> String? {
        if value is NSNull {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func looksLikeRawToolBody(_ body: String) -> Bool {
        let normalized = sanitizeIdentifier(body, fallback: "")
        return normalized.contains("calendar_create_event") ||
            normalized.contains("reminders_create_reminder") ||
            normalized.contains("params")
    }

    private static func displayBody(for tool: AIResultTool) -> String {
        let title = tool.params["title"] ?? "this"
        switch tool.name {
        case "calendar.create_event":
            if let start = tool.params["start"] {
                return "Ready to add \(title) to Calendar for \(start)."
            }
            return "Ready to add \(title) to Calendar."
        case "reminders.create_reminder":
            if let due = tool.params["due"] {
                return "Ready to add a reminder for \(title) due \(due)."
            }
            return "Ready to add a reminder for \(title)."
        default:
            return "Ready to run this action."
        }
    }
}
