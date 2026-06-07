import Foundation

@MainActor
struct SummaryPipelineEvents {
    var debug: (String) -> Void
    var savedCapture: (CaptureRecord) -> Void
    var webSearchStarted: () -> Void
    var partialResult: (StreamingResultSnapshot) -> Void
    var completed: (SummaryRecord, String) -> Void
    var failed: (CodexSummarizerError, String) -> Void
}

@MainActor
final class SummaryPipeline {
    private let captureStore: CaptureStore
    private let summarizationLock: SummarizationLock
    private let backendRouter: InferenceBackendRouter
    private var activeLockToken: SummarizationLockToken?

    init(
        captureStore: CaptureStore,
        summarizationLock: SummarizationLock,
        backendRouter: InferenceBackendRouter
    ) {
        self.captureStore = captureStore
        self.summarizationLock = summarizationLock
        self.backendRouter = backendRouter
    }

    var isRunning: Bool {
        activeLockToken != nil
    }

    func reserveForCapture() -> Result<Void, Error> {
        acquireLock()
    }

    func releaseReservedCapture() {
        releaseLock()
    }

    func run(
        capture: CapturedText,
        model: String,
        lockAlreadyAcquired: Bool,
        events: SummaryPipelineEvents
    ) {
        if lockAlreadyAcquired == false {
            switch acquireLock() {
            case .success:
                break
            case .failure(let error):
                events.failed(.saveFailed(error.localizedDescription), providerLabel(for: model))
                return
            }
        }

        let backend = backendRouter.backend(for: model)
        let providerLabel = backend.providerLabel(for: model)

        do {
            events.debug("""
            Capture source: \(capture.source.rawValue)
            Captured characters: \(capture.text.count)
            Saving capture...
            """)
            let record = try captureStore.save(capture.text)
            events.savedCapture(record)
            events.debug("Launching \(providerLabel)...")

            backend.summarize(
                record: record,
                model: model,
                callbacks: InferenceBackendCallbacks(
                    onProcessStarted: { [weak self] processIdentifier in
                        self?.markProcess(processIdentifier)
                        if processIdentifier > 0 {
                            events.debug("\(providerLabel) PID: \(processIdentifier)")
                        } else {
                            events.debug("\(providerLabel) request sent")
                        }
                    },
                    onWebSearchStarted: {
                        events.webSearchStarted()
                        events.debug("Entering web search verification phase...")
                    },
                    onDebug: { message in
                        events.debug(message)
                    },
                    onPartialResult: { snapshot in
                        events.partialResult(snapshot)
                    }
                )
            ) { [weak self] result in
                self?.releaseLock()
                switch result {
                case .success(let summary):
                    events.completed(summary, providerLabel)
                case .failure(let error):
                    events.failed(error, providerLabel)
                }
            }
        } catch {
            releaseLock()
            events.failed(.saveFailed(error.localizedDescription), providerLabel)
        }
    }

    private func providerLabel(for model: String) -> String {
        backendRouter.backend(for: model).providerLabel(for: model)
    }

    private func acquireLock() -> Result<Void, Error> {
        guard activeLockToken == nil else {
            return .failure(SummarizationPipelineError.alreadyRunning)
        }

        do {
            activeLockToken = try summarizationLock.acquire()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func releaseLock() {
        guard let activeLockToken else {
            return
        }

        summarizationLock.release(activeLockToken)
        self.activeLockToken = nil
    }

    private func markProcess(_ processIdentifier: Int32) {
        guard let activeLockToken else {
            return
        }

        summarizationLock.updateProcessIdentifier(processIdentifier, for: activeLockToken)
    }
}

private enum SummarizationPipelineError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        "Already summarizing. Wait for the current summary to finish."
    }
}
