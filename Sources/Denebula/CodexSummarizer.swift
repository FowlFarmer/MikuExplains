import Foundation

enum CodexSummarizerError: LocalizedError {
    case codexExecutableNotFound
    case launchFailed(String)
    case failed(status: Int32, output: String)
    case unreadableOutput(String)
    case invalidOutput(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            "Could not find the Codex CLI. Install or open Codex so Denebula can use its login."
        case .launchFailed(let message):
            "Could not launch Codex: \(message)"
        case .failed(let status, let output):
            "Codex inference failed with status \(status): \(output)"
        case .unreadableOutput(let message):
            "Could not read Codex output: \(message)"
        case .invalidOutput(let output):
            "Codex returned an invalid result format: \(output)"
        case .saveFailed(let message):
            "Could not save Codex result: \(message)"
        }
    }
}

final class CodexSummarizer: @unchecked Sendable {
    private let fileManager: FileManager
    private let captureStore: CaptureStore

    init(fileManager: FileManager = .default, captureStore: CaptureStore) {
        self.fileManager = fileManager
        self.captureStore = captureStore
    }

    func summarize(
        record: CaptureRecord,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        onWebSearchStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        guard let codexURL = codexExecutableURL() else {
            complete(.failure(.codexExecutableNotFound), completion: completion)
            return
        }

        runCodex(
            codexURL: codexURL,
            record: record,
            prompt: localInferencePrompt(for: record),
            usesWebSearch: false,
            onProcessStarted: onProcessStarted
        ) { [self, captureStore] result in
            switch result {
            case .failure(let error):
                complete(.failure(error), completion: completion)
            case .success(let localResult):
                guard localResult.needsWebSearch else {
                    save(localResult, record: record, captureStore: captureStore, completion: completion)
                    return
                }

                Task { @MainActor in
                    onWebSearchStarted()
                }

                runCodex(
                    codexURL: codexURL,
                    record: record,
                    prompt: webInferencePrompt(for: record, localResult: localResult),
                    usesWebSearch: true,
                    onProcessStarted: onProcessStarted
                ) { [self, captureStore] webResult in
                    switch webResult {
                    case .success(let finalResult):
                        save(finalResult, record: record, captureStore: captureStore, completion: completion)
                    case .failure(let error):
                        complete(.failure(error), completion: completion)
                    }
                }
            }
        }
    }

    private func runCodex(
        codexURL: URL,
        record: CaptureRecord,
        prompt: String,
        usesWebSearch: Bool,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        completion: @escaping @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    ) {
        let process = Process()
        process.executableURL = codexURL
        process.currentDirectoryURL = record.captureURL.deletingLastPathComponent()

        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            record.rawSummaryURL.path,
            prompt
        ]

        if usesWebSearch {
            arguments.insert("--search", at: 0)
        }

        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { process in
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                completion(.failure(.failed(status: process.terminationStatus, output: output)))
                return
            }

            do {
                let rawOutput = try String(contentsOf: record.rawSummaryURL, encoding: .utf8)
                let parsedResult = try ParsedCodexSummary.parse(rawOutput)
                completion(.success(parsedResult))
            } catch let error as CodexSummarizerError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unreadableOutput(error.localizedDescription)))
            }
        }

        do {
            try process.run()
            Task { @MainActor in
                onProcessStarted(process.processIdentifier)
            }
        } catch {
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    private func save(
        _ result: ParsedCodexSummary,
        record: CaptureRecord,
        captureStore: CaptureStore,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        do {
            let savedResult = try captureStore.saveSummary(result, for: record)
            complete(.success(savedResult), completion: completion)
        } catch {
            complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
        }
    }

    private func complete(
        _ result: Result<SummaryRecord, CodexSummarizerError>,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func codexExecutableURL() -> URL? {
        let bundledCodex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if fileManager.isExecutableFile(atPath: bundledCodex.path) {
            return bundledCodex
        }

        let usrLocalCodex = URL(fileURLWithPath: "/usr/local/bin/codex")
        if fileManager.isExecutableFile(atPath: usrLocalCodex.path) {
            return usrLocalCodex
        }

        let optHomebrewCodex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        if fileManager.isExecutableFile(atPath: optHomebrewCodex.path) {
            return optHomebrewCodex
        }

        return nil
    }

    private func localInferencePrompt(for record: CaptureRecord) -> String {
        let hints = TextInferenceHints(captureURL: record.captureURL).promptText
        return """
        Read the Markdown file at this path:
        \(record.captureURL.path)

        Denebula is a highlight-to-AI-action app. Infer what the user likely wants from the highlighted text, then return the smallest useful set of result cards.

        Local deterministic hints:
        \(hints)

        Use these v1 intents when appropriate: definition, translation, summary, validity, assumptions, core_point, actions, reply_draft, code_help, web_context.

        Rules:
        - Return only valid JSON. No Markdown fence.
        - Always consider English as the user's preferred output language unless the selected text explicitly asks for another language.
        - If the selected text is not English, treat translation into English as the likely primary intent unless another intent is clearly more useful.
        - If the selected text is five words or fewer and looks like terminology, prefer a definition card.
        - Do not force a summary card. Include summary only when it is genuinely useful or when intent confidence is low.
        - If intent confidence is low, use primary_intent "summary" and include 2 or 3 broadly helpful cards.
        - Prefer 1 to 3 cards total.
        - Set needs_web_search true only for factual claims, current events, named entities, citations, or source-backed verification where web context would materially improve the answer.
        - If needs_web_search is true, still include a useful local result, but avoid pretending to verify facts from memory.
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.

        JSON shape:
        {
          "tagline": "1 to 4 words",
          "primary_intent": "definition",
          "intent_confidence": "low|medium|high",
          "needs_web_search": false,
          "used_web_search": false,
          "cards": [
            {
              "type": "definition",
              "title": "Definition",
              "body": "Card body text.",
              "confidence": "optional low|medium|high"
            }
          ]
        }
        """
    }

    private func webInferencePrompt(for record: CaptureRecord, localResult: ParsedCodexSummary) -> String {
        let localJSON = (try? localResult.jsonString()) ?? ""
        return """
        Read the Markdown file at this path:
        \(record.captureURL.path)

        Denebula already ran a local inference pass and decided web search is useful. Use live web search for claim verification, citations, or current context, then return the final Denebula result.

        Local pass JSON:
        \(localJSON)

        Rules:
        - Return only valid JSON. No Markdown fence.
        - Preserve the best local cards when useful, but replace weak validity/context cards with web-grounded ones.
        - Include sources or source names in card bodies when web search informs the answer.
        - Set needs_web_search false and used_web_search true.
        - Prefer 1 to 3 cards total.
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.

        JSON shape:
        {
          "tagline": "1 to 4 words",
          "primary_intent": "validity",
          "intent_confidence": "low|medium|high",
          "needs_web_search": false,
          "used_web_search": true,
          "cards": [
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

private struct TextInferenceHints {
    let captureURL: URL

    var promptText: String {
        guard let text = try? String(contentsOf: captureURL, encoding: .utf8) else {
            return "- Could not read local text for hints."
        }

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
        if trimmed.range(of: #"\d"#, options: .regularExpression) != nil {
            hints.append("- Contains numbers: consider numerical sanity or validity.")
        }

        return hints.joined(separator: "\n")
    }
}

struct AIResultCard: Codable {
    let type: String
    let title: String
    let body: String
    let confidence: String?
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
                    AIResultCard(
                        type: sanitizeIdentifier(card.type, fallback: "note"),
                        title: sanitizeTitle(card.title, fallback: "Note"),
                        body: card.body.trimmingCharacters(in: .whitespacesAndNewlines),
                        confidence: card.confidence.map { sanitizeIdentifier($0, fallback: "medium") }
                    )
                }
                .filter { $0.body.isEmpty == false }

            guard sanitizedCards.isEmpty == false else {
                throw CodexSummarizerError.invalidOutput(output)
            }

            return ParsedCodexSummary(
                tagline: sanitizeTagline(decoded.tagline),
                primaryIntent: sanitizeIdentifier(decoded.primaryIntent, fallback: "summary"),
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

    private static func sanitizeTagline(_ tagline: String) -> String {
        let cleaned = tagline.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(.whitespaces).contains(scalar) ? Character(scalar) : " "
        }.reduce(into: "") { result, character in
            result.append(character)
        }

        let words = cleaned
            .split(separator: " ")
            .prefix(4)
            .map(String.init)

        return words.isEmpty ? "AI Result" : words.joined(separator: " ")
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
        return cleaned.isEmpty ? fallback : cleaned
    }
}
