import Foundation

/// Reuses Google explicit context caching for hosted Gemini models that support it.
final class GeminiAPIContextCache: @unchecked Sendable {
    static let shared = GeminiAPIContextCache()

    private static let cacheTTLSeconds = 3600
    private static let refreshLeadTime: TimeInterval = 300

    private let lock = NSLock()
    private var entry: Entry?

    private struct Entry {
        let name: String
        let expireTime: Date
        let apiModel: String
        let promptVersion: String
    }

    private init() {}

    func ensureCachedContent(
        apiModel: String,
        apiKey: String,
        session: URLSession,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @Sendable (Result<String?, CodexSummarizerError>) -> Void
    ) {
        let promptVersion = InferencePromptBuilder.geminiAPISystemPromptVersion
        if let name = validCacheName(apiModel: apiModel, promptVersion: promptVersion) {
            completion(.success(name))
            return
        }

        createCache(
            apiModel: apiModel,
            apiKey: apiKey,
            promptVersion: promptVersion,
            session: session,
            callbacks: callbacks,
            completion: completion
        )
    }

    private func validCacheName(apiModel: String, promptVersion: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry,
              entry.apiModel == apiModel,
              entry.promptVersion == promptVersion,
              entry.expireTime.timeIntervalSinceNow > Self.refreshLeadTime else {
            return nil
        }

        return entry.name
    }

    private func storeEntry(name: String, expireTime: Date, apiModel: String, promptVersion: String) {
        lock.lock()
        entry = Entry(name: name, expireTime: expireTime, apiModel: apiModel, promptVersion: promptVersion)
        lock.unlock()
    }

    private func createCache(
        apiModel: String,
        apiKey: String,
        promptVersion: String,
        session: URLSession,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @Sendable (Result<String?, CodexSummarizerError>) -> Void
    ) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/cachedContents"

        guard let url = components.url else {
            completion(.success(nil))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = GeminiCreateCachedContentRequest(
            model: "models/\(apiModel)",
            displayName: "miku-explains-\(apiModel)-\(promptVersion)",
            ttl: "\(Self.cacheTTLSeconds)s",
            systemInstruction: GeminiCachedContent(
                role: nil,
                parts: [.init(text: InferencePromptBuilder.geminiAPISystemInstruction())]
            ),
            contents: [
                GeminiCachedContent(
                    role: "user",
                    parts: [.init(text: InferencePromptBuilder.geminiAPICacheReferenceCorpus())]
                )
            ]
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.success(nil))
            return
        }

        Task { @MainActor in
            callbacks.onDebug("Gemini API context cache: creating cachedContents for \(apiModel).")
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                completion(.success(nil))
                return
            }

            if let error {
                Task { @MainActor in
                    callbacks.onDebug("Gemini API context cache create failed: \(error.localizedDescription)")
                }
                completion(.success(nil))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                let message = Self.parseErrorMessage(from: data)
                    ?? String(data: data ?? Data(), encoding: .utf8)
                    ?? "HTTP \(statusCode)"
                Task { @MainActor in
                    callbacks.onDebug("Gemini API context cache create HTTP \(statusCode): \(message)")
                }
                completion(.success(nil))
                return
            }

            guard let data,
                  let decoded = try? JSONDecoder().decode(GeminiCachedContentResponse.self, from: data),
                  let name = decoded.name,
                  name.isEmpty == false else {
                completion(.success(nil))
                return
            }

            let expireTime = Self.parseExpireTime(decoded.expireTime)
                ?? Date().addingTimeInterval(TimeInterval(Self.cacheTTLSeconds))

            self.storeEntry(name: name, expireTime: expireTime, apiModel: apiModel, promptVersion: promptVersion)

            Task { @MainActor in
                if let tokenCount = decoded.usageMetadata?.totalTokenCount {
                    callbacks.onDebug("Gemini API context cache created: \(name) (\(tokenCount) cached tokens).")
                } else {
                    callbacks.onDebug("Gemini API context cache created: \(name).")
                }
            }

            completion(.success(name))
        }.resume()
    }

    private static func parseExpireTime(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct GeminiCreateCachedContentRequest: Encodable {
    let model: String
    let displayName: String
    let ttl: String
    let systemInstruction: GeminiCachedContent
    let contents: [GeminiCachedContent]
}

private struct GeminiCachedContent: Encodable {
    let role: String?
    let parts: [GeminiCachedPart]
}

private struct GeminiCachedPart: Encodable {
    let text: String
}

private struct GeminiCachedContentResponse: Decodable {
    let name: String?
    let expireTime: String?
    let usageMetadata: GeminiCacheUsageMetadata?
    let error: GeminiCachedContentError?
}

private struct GeminiCacheUsageMetadata: Decodable {
    let totalTokenCount: Int?
}

private struct GeminiCachedContentError: Decodable {
    let message: String?
}

extension GeminiAPIContextCache {
    fileprivate static func parseErrorMessage(from data: Data?) -> String? {
        guard let data else {
            return nil
        }

        if let decoded = try? JSONDecoder().decode(GeminiCachedContentResponse.self, from: data),
           let message = decoded.error?.message,
           message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return message
        }

        return nil
    }
}
