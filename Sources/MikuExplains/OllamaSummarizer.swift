import Foundation

/// Inference backend that calls a local Ollama server via its OpenAI-compatible
/// `/v1/chat/completions` endpoint. Mirrors the public interface of
/// `CodexSummarizer` so `AppDelegate` can swap between them transparently.
///
/// Configure with environment variables (or leave defaults):
///   MIKU_OLLAMA_BASE   — base URL, default http://localhost:11434
///   MIKU_OLLAMA_MODEL  — model tag, default llama3
final class OllamaSummarizer: @unchecked Sendable {
    private let captureStore: CaptureStore
    private let baseURL: URL
    private let model: String

    init(captureStore: CaptureStore) {
        self.captureStore = captureStore
        let base = ProcessInfo.processInfo.environment["MIKU_OLLAMA_BASE"]
            ?? "http://localhost:11434"
        self.baseURL = URL(string: base) ?? URL(string: "http://localhost:11434")!
        // model is passed per-call; this default is unused
        self.model = ProcessInfo.processInfo.environment["MIKU_OLLAMA_MODEL"] ?? "llama3"
    }

    func summarize(
        record: CaptureRecord,
        model: String,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        onWebSearchStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        // Signal "started" with PID 0 (no subprocess).
        Task { @MainActor in onProcessStarted(0) }

        let prompt = localInferencePrompt(for: record)

        callOllama(prompt: prompt, model: model) { [self] result in
            switch result {
            case .failure(let error):
                self.complete(.failure(error), completion: completion)
            case .success(let localResult):
                // Ollama has no web-search capability; skip the second pass.
                self.save(localResult, record: record, captureStore: self.captureStore, completion: completion)
            }
        }
    }

    // MARK: - Private

    private func callOllama(
        prompt: String,
        model: String,
        completion: @escaping @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "stream": false
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(.launchFailed("Could not encode request body")))
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.failed(status: -1, output: error.localizedDescription)))
                return
            }

            guard let data = data else {
                completion(.failure(.unreadableOutput("Empty response from Ollama")))
                return
            }

            // Parse the OpenAI-compatible response envelope.
            guard
                let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = envelope["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                completion(.failure(.unreadableOutput("Unexpected Ollama response: \(raw)")))
                return
            }

            do {
                let parsed = try ParsedCodexSummary.parse(content)
                completion(.success(parsed))
            } catch let err as CodexSummarizerError {
                completion(.failure(err))
            } catch {
                completion(.failure(.invalidOutput(content)))
            }
        }.resume()
    }

    private func save(
        _ result: ParsedCodexSummary,
        record: CaptureRecord,
        captureStore: CaptureStore,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        do {
            let saved = try captureStore.saveSummary(result, for: record)
            complete(.success(saved), completion: completion)
        } catch {
            complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
        }
    }

    private func complete(
        _ result: Result<SummaryRecord, CodexSummarizerError>,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        Task { @MainActor in completion(result) }
    }

    // MARK: - Prompts (identical to CodexSummarizer minus the file-path preamble)

    private func localInferencePrompt(for record: CaptureRecord) -> String {
        guard let text = try? String(contentsOf: record.captureURL, encoding: .utf8) else {
            return "No text available."
        }
        let hints = TextInferenceHintsOllama(text: text).promptText
        return """
        The user highlighted this text:

        \(text)

        Miku Explains is a whimsical highlight-to-AI-action app. Infer what the user likely wants from the highlighted text, then return the smallest useful list of UI items.

        Local deterministic hints:
        \(hints)

        Use these item types exactly when appropriate: definition, translation, summary, core_point, assumptions, validity, actions, reply_draft, code_help, web_context, numerical_sanity, glossary, contrarian, note.

        Rules:
        - Return only valid JSON. No Markdown fence, no preamble.
        - Always consider English as the user's preferred output language unless the selected text explicitly asks for another language.
        - If the selected text is not English, treat translation into English as the likely primary intent unless another intent is clearly more useful.
        - If the selected text is five words or fewer and looks like terminology, prefer a definition card.
        - Each item is rendered as a separate card. Do not combine unrelated sections inside one item body.
        - Do not force a summary item. Include summary only when it is genuinely useful or when intent confidence is low.
        - If intent confidence is low, use primary_intent "summary" and include 2 or 3 likely helpful items.
        - Prefer 1 to 3 items total.
        - Use concise titles that name the action, such as "Definition", "Translate", "What matters", "Assumptions", "Check this", or "Try this".
        - Set needs_web_search false (Ollama has no web access).
        - Use regular ASCII characters in tagline, intent, type, title, and confidence.

        JSON shape:
        {
          "tagline": "1 to 4 words",
          "primary_intent": "definition",
          "intent_confidence": "low|medium|high",
          "needs_web_search": false,
          "used_web_search": false,
          "items": [
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
}

// Lightweight hint builder that works from raw text (no file URL needed for
// the Ollama path since the text is inlined into the prompt directly).
private struct TextInferenceHintsOllama {
    let text: String

    var promptText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.map(String.init)
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
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("def ") || trimmed.hasPrefix("class ") {
            hints.append("- Looks like code: prefer code_help or definition.")
        }
        return hints.joined(separator: "\n")
    }
}
