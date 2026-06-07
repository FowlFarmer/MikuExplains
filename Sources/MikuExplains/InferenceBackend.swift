import Foundation

struct InferenceBackendCallbacks {
    let onProcessStarted: @MainActor @Sendable (Int32) -> Void
    let onWebSearchStarted: @MainActor @Sendable () -> Void
    let onDebug: @MainActor @Sendable (String) -> Void
    let onPartialResult: @MainActor @Sendable (StreamingResultSnapshot) -> Void
}

struct StreamingResultSnapshot {
    let title: String
    let primaryIntent: String
    let cards: [AIResultCard]
}

protocol InferenceBackend: AnyObject {
    func providerLabel(for model: String) -> String
    func summarize(
        record: CaptureRecord,
        model: String,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    )
}

final class InferenceBackendRouter: @unchecked Sendable {
    private let codexBackend: InferenceBackend
    private let llamaCppBackend: InferenceBackend

    init(codexBackend: InferenceBackend, llamaCppBackend: InferenceBackend) {
        self.codexBackend = codexBackend
        self.llamaCppBackend = llamaCppBackend
    }

    func backend(for model: String) -> InferenceBackend {
        model == "codex" ? codexBackend : llamaCppBackend
    }
}

extension CodexSummarizer: InferenceBackend {
    func providerLabel(for model: String) -> String {
        "Codex"
    }

    func summarize(
        record: CaptureRecord,
        model: String,
        callbacks: InferenceBackendCallbacks,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        summarize(
            record: record,
            onProcessStarted: callbacks.onProcessStarted,
            onWebSearchStarted: callbacks.onWebSearchStarted,
            completion: completion
        )
    }
}
