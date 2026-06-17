import Foundation

enum GeminiKeyAccessResult {
    case ready
    case missingKey
    case permissionDenied
}

/// Orchestrates the Gemma Keychain flow: silent probe first, heads-up before any
/// interactive Keychain prompt, then macOS permission on "got it".
@MainActor
final class GeminiKeychainCoordinator {
    private let store: GeminiAPIKeyStore
    private(set) var isHeadsUpVisible = false
    private(set) var hasStartedKeychainFlow = false
    private var pendingCompletions: [(GeminiKeyAccessResult) -> Void] = []

    init(store: GeminiAPIKeyStore = .shared) {
        self.store = store
    }

    func panelKeyConfigured(isGemmaSelected: Bool) -> Bool? {
        guard isGemmaSelected else {
            return nil
        }

        guard hasStartedKeychainFlow else {
            return store.hasEnvironmentKey ? true : nil
        }

        switch store.accessState() {
        case .available:
            return true
        case .missing:
            return false
        case .needsPermission:
            return nil
        case .failed:
            return false
        }
    }

    func debugSnapshot(probeKeychain: Bool) -> String {
        let shouldProbe = probeKeychain || hasStartedKeychainFlow
        let stateLabel = shouldProbe ? store.accessState().debugLabel : "deferred"
        let storeSummary = shouldProbe ? store.debugSummary() : "source=deferred"
        return [
            "state=\(stateLabel)",
            "headsUp=\(isHeadsUpVisible)",
            "started=\(hasStartedKeychainFlow)",
            "pending=\(pendingCompletions.count)",
            "envKey=\(store.hasEnvironmentKey)",
            storeSummary
        ].joined(separator: " ")
    }

    /// Resolves Gemma Keychain access without ever showing macOS UI before the heads-up.
    func requestAccess(
        presentHeadsUp: () -> Void,
        log: (String) -> Void,
        completion: @escaping (GeminiKeyAccessResult) -> Void
    ) {
        hasStartedKeychainFlow = true
        let state = store.accessState()
        log("Gemini Keychain requestAccess state=\(state.debugLabel) \(debugSnapshot(probeKeychain: true))")

        switch state {
        case .available:
            completion(.ready)
        case .missing:
            completion(.missingKey)
        case .needsPermission:
            queueHeadsUp(presentHeadsUp: presentHeadsUp, log: log, completion: completion)
        case .failed:
            completion(.permissionDenied)
        }
    }

    func acknowledgeHeadsUp(log: (String) -> Void) -> GeminiKeyAccessResult {
        log("Gemini Keychain heads-up acknowledged — showing macOS permission prompt")
        isHeadsUpVisible = false

        let key = store.readKey(allowUI: true)
        let result: GeminiKeyAccessResult
        if let key, key.isEmpty == false {
            log("Gemini Keychain interactive read succeeded (len=\(key.count))")
            result = .ready
        } else {
            switch store.accessState() {
            case .missing:
                log("Gemini Keychain interactive read: no stored key")
                result = .missingKey
            default:
                log("Gemini Keychain interactive read: permission denied or failed")
                result = .permissionDenied
            }
        }

        let completions = pendingCompletions
        pendingCompletions = []
        completions.forEach { $0(result) }
        return result
    }

    private func queueHeadsUp(
        presentHeadsUp: () -> Void,
        log: (String) -> Void,
        completion: @escaping (GeminiKeyAccessResult) -> Void
    ) {
        pendingCompletions.append(completion)

        guard isHeadsUpVisible == false else {
            log("Gemini Keychain heads-up already visible — queued completion")
            return
        }

        isHeadsUpVisible = true
        log("Gemini Keychain showing heads-up before permission prompt")
        presentHeadsUp()
    }
}
