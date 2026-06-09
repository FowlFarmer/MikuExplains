import Foundation

struct GeminiAPIModelInfo {
    let apiModel: String
    let displayName: String
}

enum GeminiAPIModelRegistry {
    static let modelRegistry: [String: GeminiAPIModelInfo] = [
        "google:gemma-4-26b-a4b-it": .init(
            apiModel: "gemma-4-26b-a4b-it",
            displayName: "Gemma 4 MoE"
        )
    ]

    static let retiredModelAliases: [String: String] = [
        "google:gemma-4-31b-it": "google:gemma-4-26b-a4b-it"
    ]

    static func isGemmaAPIModel(_ model: String) -> Bool {
        modelRegistry[model] != nil
    }

    static func info(for model: String) -> GeminiAPIModelInfo? {
        modelRegistry[model]
    }

    static func canonicalModelTag(for tag: String) -> String {
        retiredModelAliases[tag] ?? tag
    }
}

final class GeminiAPISummarizer: @unchecked Sendable, InferenceBackend {
    private let captureStore: CaptureStore
    private let apiKeyStore: GeminiAPIKeyStore
    private let requestTimeout: TimeInterval

    init(captureStore: CaptureStore, apiKeyStore: GeminiAPIKeyStore = .shared) {
        self.captureStore = captureStore
        self.apiKeyStore = apiKeyStore
        self.requestTimeout = 45
    }

    func providerLabel(for model: String) -> String {
        guard let info = GeminiAPIModelRegistry.info(for: model) else {
            return "Google Gemini API"
        }

        return "Google Gemini API/\(info.displayName)"
    }

    func summarize(
        record: CaptureRecord,
        model: String,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        Task { @MainActor in callbacks.onProcessStarted(0) }

        guard let info = GeminiAPIModelRegistry.info(for: model) else {
            complete(.failure(.saveFailed("Unknown Google API model: \(model)")), completion: completion)
            return
        }

        guard let apiKey = apiKeyStore.apiKey() else {
            complete(.failure(.saveFailed("Missing Gemini API key. Add one in the model menu or set GEMINI_API_KEY.")), completion: completion)
            return
        }

        let prompt = InferencePromptBuilder.localPrompt(for: record, backend: .geminiAPI)
        let useThinking = false

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            callGeminiAPI(
                apiModel: info.apiModel,
                apiKey: apiKey,
                prompt: prompt,
                useThinking: useThinking,
                callbacks: callbacks
            ) { [self] result in
                switch result {
                case .failure(let error):
                    complete(.failure(error), completion: completion)
                case .success(let output):
                    do {
                        try output.write(to: record.rawSummaryURL, atomically: true, encoding: .utf8)
                        let parsed = Self.parseOrWrapInstructionFailure(output)
                        let saved = try captureStore.saveSummary(parsed, for: record)
                        complete(.success(saved), completion: completion)
                    } catch {
                        complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
                    }
                }
            }
        }
    }

    private func callGeminiAPI(
        apiModel: String,
        apiKey: String,
        prompt: String,
        useThinking: Bool,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @Sendable (Result<String, CodexSummarizerError>) -> Void
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/models/\(apiModel):generateContent"

        guard let url = components.url else {
            completion(.failure(.launchFailed("Invalid Gemini API URL.")))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = GeminiGenerateContentRequest(
            contents: [
                .init(parts: [.init(text: prompt)])
            ],
            generationConfig: .init(
                responseMimeType: "application/json",
                temperature: 0.2,
                maxOutputTokens: 1024,
                thinkingConfig: nil
            )
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(.launchFailed(error.localizedDescription)))
            return
        }

        Task { @MainActor in
            callbacks.onDebug("Gemma API thinking mode disabled.")
            callbacks.onDebug("Gemma API endpoint: v1beta \(apiModel):generateContent.")
            callbacks.onDebug("Gemma API request sent to generateContent.")
            callbacks.onDebug("Gemma API waiting for response (45s timeout).")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(requestTimeout, 20)
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let completionBox = GeminiAPICompletionBox(completion: completion)
        let timeout = requestTimeout
        let task = session.dataTask(with: request) { data, response, error in
            defer {
                session.finishTasksAndInvalidate()
            }

            if let error {
                Task { @MainActor in
                    callbacks.onDebug("Gemma API network error: \(error.localizedDescription)")
                }
                completionBox.finish(.failure(.failed(status: -1, output: "Gemini API request failed: \(error.localizedDescription)")))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let rawResponse = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                callbacks.onDebug("Gemma API response status: \(statusCode), bytes: \(data?.count ?? 0).")
            }

            guard (200..<300).contains(statusCode) else {
                let message = Self.geminiAPIErrorMessage(from: data) ?? rawResponse
                completionBox.finish(.failure(.failed(status: Int32(statusCode), output: message)))
                return
            }

            guard let data else {
                completionBox.finish(.failure(.unreadableOutput("Empty response from Gemini API")))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
                if let message = decoded.error?.message, message.isEmpty == false {
                    completionBox.finish(.failure(.failed(status: Int32(statusCode), output: message)))
                    return
                }

                let output = decoded.candidates?
                    .flatMap { $0.content?.parts ?? [] }
                    .compactMap(\.text)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard output.isEmpty == false else {
                    completionBox.finish(.failure(.unreadableOutput("Gemini API returned no text candidates")))
                    return
                }

                Task { @MainActor in
                    callbacks.onDebug("Gemma API returned \(output.count) characters.")
                }
                completionBox.finish(.success(output))
            } catch {
                let fallback = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = fallback.isEmpty ? error.localizedDescription : fallback
                completionBox.finish(.failure(.unreadableOutput(message)))
            }
        }
        task.resume()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard completionBox.finish(.failure(.failed(status: -1, output: "Gemini API request timed out after \(Int(timeout)) seconds."))) else {
                return
            }
            Task { @MainActor in
                callbacks.onDebug("Gemma API timed out after \(Int(timeout)) seconds.")
            }
            task.cancel()
            session.invalidateAndCancel()
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

    private static func parseOrWrapInstructionFailure(_ output: String) -> ParsedCodexSummary {
        do {
            return try ParsedCodexSummary.parse(output)
        } catch let error as CodexSummarizerError {
            return fallbackSummary(from: output, parseError: error)
        } catch {
            return fallbackSummary(from: output, parseError: .unreadableOutput(error.localizedDescription))
        }
    }

    private static func fallbackSummary(from output: String, parseError: CodexSummarizerError) -> ParsedCodexSummary {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty
            ? "The hosted Gemma model returned an empty response."
            : trimmed

        return ParsedCodexSummary(
            tagline: "Instruction Failure",
            primaryIntent: "note",
            intentConfidence: "low",
            needsWebSearch: false,
            usedWebSearch: false,
            cards: [
                AIResultCard(
                    type: "note",
                    title: "Instruction failure",
                    body: "Instruction failure: the hosted Gemma model did not follow Miku's required JSON response format, so this card shows the raw model response instead.\n\nRaw response:\n\(body)\n\nParser note: \(parseError.localizedDescription)",
                    confidence: "low"
                )
            ]
        )
    }

    private static func geminiAPIErrorMessage(from data: Data?) -> String? {
        guard let data else {
            return nil
        }

        if let decoded = try? JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data),
           let message = decoded.error?.message,
           message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return message
        }

        return nil
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiGenerationConfig: Encodable {
    let responseMimeType: String
    let temperature: Double
    let maxOutputTokens: Int
    let thinkingConfig: GeminiThinkingConfig?
}

private struct GeminiThinkingConfig: Encodable {
    let thinkingLevel: String
}

private struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    let text: String?
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let error: GeminiAPIError?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}

private struct GeminiAPIError: Decodable {
    let message: String?
}

private final class GeminiAPICompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let completion: @Sendable (Result<String, CodexSummarizerError>) -> Void

    init(completion: @escaping @Sendable (Result<String, CodexSummarizerError>) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ result: Result<String, CodexSummarizerError>) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard didFinish == false else {
            return false
        }

        didFinish = true
        completion(result)
        return true
    }
}
