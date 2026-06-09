import Foundation

struct GeminiAPIModelInfo {
    let apiModel: String
    let displayName: String
    let supportsExplicitContextCaching: Bool
}

enum GeminiAPIModelRegistry {
    static let modelRegistry: [String: GeminiAPIModelInfo] = [
        "google:gemma-4-26b-a4b-it": .init(
            apiModel: "gemma-4-26b-a4b-it",
            displayName: "Gemma 4 MoE",
            supportsExplicitContextCaching: false
        ),
        "google:gemini-3.1-flash-lite": .init(
            apiModel: "gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash Lite",
            supportsExplicitContextCaching: true
        )
    ]

    static let retiredModelAliases: [String: String] = [
        "google:gemma-4-31b-it": "google:gemma-4-26b-a4b-it"
    ]

    static func isHostedGeminiAPIModel(_ model: String) -> Bool {
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
    private static let maxOutputTokens = 20_000

    private let captureStore: CaptureStore
    private let apiKeyStore: GeminiAPIKeyStore
    private let maxRequestDuration: TimeInterval

    init(
        captureStore: CaptureStore,
        apiKeyStore: GeminiAPIKeyStore = .shared,
        inactivityTimeout: TimeInterval = 45,
        maxRequestDuration: TimeInterval = 600
    ) {
        self.captureStore = captureStore
        self.apiKeyStore = apiKeyStore
        // `inactivityTimeout` is retained for API compatibility; Gemma uses a single
        // non-streaming request bounded by `maxRequestDuration`.
        _ = inactivityTimeout
        self.maxRequestDuration = maxRequestDuration
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

        guard let apiKey = apiKeyStore.readKey(allowUI: false) else {
            complete(.failure(.saveFailed("Missing Gemini API key. Add one in the model menu or set GEMINI_API_KEY.")), completion: completion)
            return
        }

        let userPrompt = InferencePromptBuilder.geminiAPIUserPrompt(for: record)
        let fallbackPrompt = InferencePromptBuilder.localPrompt(for: record, backend: .geminiAPI)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let configuration = Self.makeURLSessionConfiguration(maxRequestDuration: maxRequestDuration)
            let session = URLSession(configuration: configuration)

            if info.supportsExplicitContextCaching {
                GeminiAPIContextCache.shared.ensureCachedContent(
                    apiModel: info.apiModel,
                    apiKey: apiKey,
                    session: session,
                    callbacks: callbacks
                ) { [self] cacheResult in
                    switch cacheResult {
                    case .failure(let error):
                        self.complete(.failure(error), completion: completion)
                    case .success(let cachedContentName):
                        if let cachedContentName {
                            Task { @MainActor in
                                callbacks.onDebug("Gemini API generateContent will reuse cachedContent \(cachedContentName).")
                            }
                        } else {
                            Task { @MainActor in
                                callbacks.onDebug("Gemini API context cache unavailable; falling back to uncached prompt.")
                            }
                        }
                        self.runGeminiAPIRequest(
                            record: record,
                            apiModel: info.apiModel,
                            apiKey: apiKey,
                            userPrompt: userPrompt,
                            fallbackPrompt: fallbackPrompt,
                            cachedContentName: cachedContentName,
                            session: session,
                            callbacks: callbacks,
                            completion: completion
                        )
                    }
                }
            } else {
                self.runGeminiAPIRequest(
                    record: record,
                    apiModel: info.apiModel,
                    apiKey: apiKey,
                    userPrompt: userPrompt,
                    fallbackPrompt: fallbackPrompt,
                    cachedContentName: nil,
                    session: session,
                    callbacks: callbacks,
                    completion: completion
                )
            }
        }
    }

    private func runGeminiAPIRequest(
        record: CaptureRecord,
        apiModel: String,
        apiKey: String,
        userPrompt: String,
        fallbackPrompt: String,
        cachedContentName: String?,
        session: URLSession,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        callGeminiAPI(
            apiModel: apiModel,
            apiKey: apiKey,
            prompt: cachedContentName == nil ? fallbackPrompt : userPrompt,
            cachedContentName: cachedContentName,
            session: session,
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

    private static func makeURLSessionConfiguration(maxRequestDuration: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = maxRequestDuration
        configuration.timeoutIntervalForResource = maxRequestDuration
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func callGeminiAPI(
        apiModel: String,
        apiKey: String,
        prompt: String,
        cachedContentName: String?,
        session: URLSession,
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

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = GeminiGenerateContentRequest(
            contents: [
                .init(role: "user", parts: [.init(text: prompt, thought: nil)])
            ],
            generationConfig: .init(
                responseMimeType: "application/json",
                temperature: 0.2,
                maxOutputTokens: Self.maxOutputTokens
            ),
            cachedContent: cachedContentName
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(.launchFailed(error.localizedDescription)))
            return
        }

        Task { @MainActor in
            callbacks.onDebug("Gemini API thinking policy: off (no thinkingConfig).")
            callbacks.onDebug("Gemini API maxOutputTokens: \(Self.maxOutputTokens).")
            callbacks.onDebug("Gemini API endpoint: v1beta \(apiModel):generateContent.")
            if let cachedContentName {
                callbacks.onDebug("Gemini API cachedContent: \(cachedContentName).")
            }
            callbacks.onDebug("Gemini API request timeout: \(Int(maxRequestDuration))s.")
            callbacks.onDebug("Gemini API request sent.")
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                Task { @MainActor in
                    callbacks.onDebug("Gemini API network error: \(error.localizedDescription)")
                }
                completion(.failure(.failed(status: -1, output: "Gemini API request failed: \(error.localizedDescription)")))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                let message = parseGeminiAPIErrorMessage(from: data)
                    ?? String(data: data ?? Data(), encoding: .utf8)
                    ?? "HTTP \(statusCode)"
                completion(.failure(.failed(status: Int32(statusCode), output: message)))
                return
            }

            guard let data, data.isEmpty == false else {
                completion(.failure(.unreadableOutput("Gemini API returned an empty body")))
                return
            }

            let decoded = try? JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            let extracted: ExtractedGeminiAnswer
            if let decoded {
                if let message = decoded.error?.message, message.isEmpty == false {
                    completion(.failure(.failed(status: Int32(statusCode), output: message)))
                    return
                }
                extracted = Self.collectAnswerText(from: decoded)
            } else {
                let salvaged = salvageTextFromRawJSON(data)
                extracted = ExtractedGeminiAnswer(
                    answer: salvaged,
                    thoughtCharacterCount: 0,
                    salvagedFromThought: false
                )
            }

            guard extracted.answer.isEmpty == false else {
                Task { @MainActor in
                    callbacks.onDebug("Gemini API response bytes: \(data.count).")
                    callbacks.onDebug("Gemini API response preview: \(debugPreview(data)).")
                }
                completion(.failure(.unreadableOutput("Gemini API returned no usable text candidates")))
                return
            }

            Task { @MainActor in
                callbacks.onDebug("Gemini API response: \(extracted.answer.count) answer characters.")
                if extracted.salvagedFromThought {
                    callbacks.onDebug("Gemini API salvaged answer text from thought-channel parts.")
                }
                if extracted.thoughtCharacterCount > 0 {
                    callbacks.onDebug("Gemini API filtered \(extracted.thoughtCharacterCount) thought-channel characters.")
                }
                if let thoughtsTokens = decoded?.usageMetadata?.thoughtsTokenCount, thoughtsTokens > 0 {
                    callbacks.onDebug("Gemini API thoughtsTokenCount: \(thoughtsTokens).")
                }
                if let cachedTokens = decoded?.usageMetadata?.cachedContentTokenCount, cachedTokens > 0 {
                    callbacks.onDebug("Gemini API cachedContentTokenCount: \(cachedTokens).")
                }
            }
            completion(.success(extracted.answer))
        }.resume()
    }

    private func complete(
        _ result: Result<SummaryRecord, CodexSummarizerError>,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private struct ExtractedGeminiAnswer {
        let answer: String
        let thoughtCharacterCount: Int
        let salvagedFromThought: Bool
    }

    private static func collectAnswerText(
        from decoded: GeminiGenerateContentResponse
    ) -> ExtractedGeminiAnswer {
        var answerParts: [String] = []
        var thoughtParts: [String] = []

        for part in decoded.candidates?.flatMap({ $0.content?.parts ?? [] }) ?? [] {
            guard let text = part.text, text.isEmpty == false else {
                continue
            }

            if part.thought == true {
                thoughtParts.append(text)
            } else {
                answerParts.append(text)
            }
        }

        let answer = answerParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let thought = thoughtParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        if answer.isEmpty == false {
            return ExtractedGeminiAnswer(
                answer: answer,
                thoughtCharacterCount: thought.count,
                salvagedFromThought: false
            )
        }

        return ExtractedGeminiAnswer(
            answer: thought,
            thoughtCharacterCount: thought.count,
            salvagedFromThought: thought.isEmpty == false
        )
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
}

private func parseGeminiAPIErrorMessage(from data: Data?) -> String? {
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

private func debugPreview(_ data: Data, limit: Int = 240) -> String {
    let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    if raw.count <= limit {
        return raw
    }
    return String(raw.prefix(limit)) + "…"
}

private func salvageTextFromRawJSON(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = object["candidates"] as? [[String: Any]] else {
        return ""
    }

    var answerParts: [String] = []
    var thoughtParts: [String] = []

    for candidate in candidates {
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            continue
        }

        for part in parts {
            guard let text = part["text"] as? String, text.isEmpty == false else {
                continue
            }

            if part["thought"] as? Bool == true {
                thoughtParts.append(text)
            } else {
                answerParts.append(text)
            }
        }
    }

    let answer = answerParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    if answer.isEmpty == false {
        return answer
    }

    return thoughtParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct GeminiGenerateContentRequest: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
    let cachedContent: String?
}

private struct GeminiGenerationConfig: Encodable {
    let responseMimeType: String
    let temperature: Double
    let maxOutputTokens: Int
}

private struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    let text: String?
    let thought: Bool?
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
    let error: GeminiAPIError?
}

private struct GeminiUsageMetadata: Decodable {
    let thoughtsTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let cachedContentTokenCount: Int?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}

private struct GeminiAPIError: Decodable {
    let message: String?
}
