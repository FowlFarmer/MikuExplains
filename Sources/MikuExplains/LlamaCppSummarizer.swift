import Foundation

/// Inference backend that talks to a managed local `llama-server`
/// (llama.cpp's OpenAI-compatible HTTP server) via `/v1/chat/completions`.
///
/// Configure with environment variables (or leave defaults):
///   MIKU_LLAMACPP_BASE  — optional base URL override
final class LlamaCppSummarizer: @unchecked Sendable, InferenceBackend {
    private let captureStore: CaptureStore
    private let baseURL: URL
    private let requestTimeout: TimeInterval

    init(captureStore: CaptureStore) {
        self.captureStore = captureStore
        self.baseURL = LlamaCppManager.shared.baseURL
        // Local inference on small models can be slow for the first token;
        // give the request plenty of headroom.
        self.requestTimeout = 600
    }

    func providerLabel(for model: String) -> String {
        "llama.cpp/\(model)"
    }

    func summarize(
        record: CaptureRecord,
        model: String,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        // llama.cpp is a single in-process server, so there's no child PID
        // to track. Use PID 0 so crash-stale lock cleanup treats it as stale.
        Task { @MainActor in callbacks.onProcessStarted(0) }

        let prompt = InferencePromptBuilder.localPrompt(for: record, backend: .llamaCpp)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let ggufURL = LlamaCppManager.shared.ggufFileURL(for: model)
            guard FileManager.default.fileExists(atPath: ggufURL.path) else {
                complete(.failure(.saveFailed("Model not installed: \(model)")), completion: completion)
                return
            }

            switch ensureRuntimeInstalled(callbacks: callbacks) {
            case .failure(let error):
                complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
                return
            case .success:
                break
            }

            switch LlamaCppManager.shared.ensureServerRunningDetailed(modelPath: ggufURL) {
            case .failure(let error):
                complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
                return
            case .success:
                break
            }

            callServer(prompt: prompt, model: model, callbacks: callbacks) { [self] result in
                switch result {
                case .failure(let error):
                    complete(.failure(error), completion: completion)
                case .success(let parsed):
                    if let stats = LlamaCppManager.shared.latestInferenceDebugStats() {
                        Task { @MainActor in callbacks.onDebug(stats) }
                    }
                    save(parsed, record: record, captureStore: captureStore, completion: completion)
                }
            }
        }
    }

    func summarize(
        record: CaptureRecord,
        model: String,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        onWebSearchStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        summarize(
            record: record,
            model: model,
            callbacks: InferenceBackendCallbacks(
                onProcessStarted: onProcessStarted,
                onWebSearchStarted: onWebSearchStarted,
                onDebug: { _ in },
                onPartialResult: { _ in }
            ),
            completion: completion
        )
    }

    // MARK: - Private

    private func ensureRuntimeInstalled(callbacks: InferenceBackendCallbacks) -> Result<Void, LlamaCppError> {
        if LlamaCppManager.shared.isServerBinaryInstalled {
            return .success(())
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = UnsafeMutableTransfer<Result<Void, LlamaCppError>?>(nil)

        LlamaCppManager.shared.ensureServerBinaryInstalled(
            progress: { message in
                callbacks.onDebug("llama.cpp install: \(message)")
            },
            completion: { result in
                resultBox.value = result
                semaphore.signal()
            }
        )
        semaphore.wait()

        return resultBox.value ?? .failure(.serverInstallFailed("Install did not finish."))
    }

    private func callServer(
        prompt: String,
        model: String,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    ) {
        let endpoint = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.0,
            "max_tokens": 1024,
            "cache_prompt": true,
            "response_format": [
                "type": "json_object"
            ],
            "stream": true
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(.launchFailed("Could not encode request body")))
            return
        }
        request.httpBody = httpBody

        let delegate = LlamaCppChatStreamDelegate(callbacks: callbacks, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: request).resume()
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

}

private final class LlamaCppChatStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let callbacks: InferenceBackendCallbacks
    private let completion: @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    private let parser = StreamingJSONResultParser()
    private var sseBuffer = ""
    private var generatedContent = ""
    private var latestSnapshot: StreamingResultSnapshot?
    private var finishReasons: [String] = []
    private var errorData = Data()
    private var statusCode: Int?
    private var didComplete = false
    var session: URLSession?

    init(
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    ) {
        self.callbacks = callbacks
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard (statusCode ?? 200) == 200 else {
            errorData.append(data)
            return
        }

        guard let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        sseBuffer.append(chunk)
        processBufferedEvents()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard didComplete == false else {
            return
        }
        didComplete = true

        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }

        if let error {
            completion(.failure(.failed(status: -1, output: error.localizedDescription)))
            return
        }

        if let statusCode, statusCode != 200 {
            let raw = String(data: errorData, encoding: .utf8) ?? "<binary>"
            completion(.failure(.failed(status: Int32(statusCode), output: raw)))
            return
        }

        guard generatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            completion(.failure(.unreadableOutput("Empty streamed response from llama-server")))
            return
        }

        do {
            let parsed = try ParsedCodexSummary.parse(generatedContent)
            completion(.success(parsed))
        } catch let error as CodexSummarizerError {
            if let partial = Self.partialSummary(
                from: latestSnapshot,
                generatedContent: generatedContent,
                parseError: error,
                finishReasons: finishReasons
            ) {
                Task { @MainActor in
                    callbacks.onDebug(Self.partialDebugMessage(finishReasons: finishReasons))
                }
                completion(.success(partial))
                return
            }

            Task { @MainActor in
                callbacks.onDebug("Local model instruction failure: expected JSON, got non-JSON output. Wrapping raw response as a note.")
            }
            completion(.success(Self.fallbackSummary(from: generatedContent, parseError: error, finishReasons: finishReasons)))
        } catch {
            if let partial = Self.partialSummary(
                from: latestSnapshot,
                generatedContent: generatedContent,
                parseError: nil,
                finishReasons: finishReasons
            ) {
                Task { @MainActor in
                    callbacks.onDebug(Self.partialDebugMessage(finishReasons: finishReasons))
                }
                completion(.success(partial))
                return
            }

            Task { @MainActor in
                callbacks.onDebug("Local model instruction failure: expected JSON, got non-JSON output. Wrapping raw response as a note.")
            }
            completion(.success(Self.fallbackSummary(from: generatedContent, parseError: nil, finishReasons: finishReasons)))
        }
    }

    private static func partialSummary(
        from snapshot: StreamingResultSnapshot?,
        generatedContent: String,
        parseError: CodexSummarizerError?,
        finishReasons: [String]
    ) -> ParsedCodexSummary? {
        guard let snapshot else {
            return nil
        }

        let cards = snapshot.cards.filter {
            $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard cards.isEmpty == false else {
            return nil
        }

        let noteTitle = outputEndedByLength(finishReasons) || looksTruncatedJSON(generatedContent)
            ? "Local output cut off"
            : "Local output incomplete"
        let noteBody = [
            "The local model ended before it produced complete JSON, so Miku saved the streamed cards that arrived before the cutoff.",
            finishReasonText(finishReasons),
            parserNote(parseError)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return ParsedCodexSummary(
            tagline: snapshot.title.isEmpty ? "Partial Result" : snapshot.title,
            primaryIntent: snapshot.primaryIntent.isEmpty ? "note" : snapshot.primaryIntent,
            intentConfidence: "low",
            needsWebSearch: false,
            usedWebSearch: false,
            cards: cards + [
                AIResultCard(
                    type: "note",
                    title: noteTitle,
                    body: noteBody,
                    confidence: "low"
                )
            ]
        )
    }

    private static func fallbackSummary(
        from output: String,
        parseError: CodexSummarizerError?,
        finishReasons: [String]
    ) -> ParsedCodexSummary {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty
            ? "The local model returned an empty response."
            : trimmed
        let errorNote = parseError?.localizedDescription ?? "The local model did not return valid JSON."
        let wasCutOff = outputEndedByLength(finishReasons) || looksTruncatedJSON(output)
        let title = wasCutOff ? "Local output cut off" : "Instruction failure"
        let failureNote = wasCutOff
            ? "The local model stopped before completing its JSON response, so this card shows the raw partial response instead."
            : "Instruction failure: the local model did not follow Miku's required JSON response format, so this card shows the raw model response instead."

        return ParsedCodexSummary(
            tagline: wasCutOff ? "Output Cut Off" : "Instruction Failure",
            primaryIntent: "note",
            intentConfidence: "low",
            needsWebSearch: false,
            usedWebSearch: false,
            cards: [
                AIResultCard(
                    type: "note",
                    title: title,
                    body: "\(failureNote)\n\n\(finishReasonText(finishReasons))\n\nRaw response:\n\(body)\n\nParser note: \(errorNote)",
                    confidence: "low"
                )
            ]
        )
    }

    private static func partialDebugMessage(finishReasons: [String]) -> String {
        let reason = finishReasonText(finishReasons)
        return "Local model returned incomplete JSON. Saved streamed partial cards. \(reason)"
    }

    private static func finishReasonText(_ finishReasons: [String]) -> String {
        let reasons = finishReasons
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard reasons.isEmpty == false else {
            return "Finish reason: unavailable from llama-server."
        }

        return "Finish reason: \(Array(Set(reasons)).sorted().joined(separator: ", "))."
    }

    private static func outputEndedByLength(_ finishReasons: [String]) -> Bool {
        finishReasons.contains { reason in
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "length" || normalized == "max_tokens"
        }
    }

    private static func parserNote(_ parseError: CodexSummarizerError?) -> String? {
        guard let parseError else {
            return nil
        }

        switch parseError {
        case .invalidOutput:
            return "Parser note: final JSON was incomplete or invalid."
        default:
            return "Parser note: \(parseError.localizedDescription)"
        }
    }

    private static func looksTruncatedJSON(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            return false
        }
        return trimmed.hasSuffix("}") == false
    }

    private func processBufferedEvents() {
        while let newlineRange = sseBuffer.range(of: "\n") {
            let rawLine = String(sseBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            sseBuffer.removeSubrange(...newlineRange.lowerBound)

            guard rawLine.hasPrefix("data:") else {
                continue
            }

            let dataLine = rawLine
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard dataLine != "[DONE]" else {
                continue
            }

            processStreamingJSONLine(String(dataLine))
        }
    }

    private func processStreamingJSONLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let first = choices.first else {
            return
        }

        if let finishReason = first["finish_reason"] as? String,
           finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            finishReasons.append(finishReason)
        }

        let delta = first["delta"] as? [String: Any]
        let message = first["message"] as? [String: Any]
        guard let content = delta?["content"] as? String ?? message?["content"] as? String,
              content.isEmpty == false else {
            return
        }

        generatedContent.append(content)
        guard let snapshot = parser.snapshot(from: generatedContent) else {
            return
        }

        latestSnapshot = snapshot
        Task { @MainActor in
            callbacks.onPartialResult(snapshot)
        }
    }
}
