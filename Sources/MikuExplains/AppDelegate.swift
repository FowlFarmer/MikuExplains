import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let textReader = SelectedTextReader()
    private let captureStore = CaptureStore()
    private let toolExecutor = MikuToolExecutor()
    private lazy var codexSummarizer = CodexSummarizer(captureStore: captureStore)
    private lazy var llamaCppSummarizer = LlamaCppSummarizer(captureStore: captureStore)
    private lazy var geminiAPISummarizer = GeminiAPISummarizer(captureStore: captureStore)
    private lazy var backendRouter = InferenceBackendRouter(
        codexBackend: codexSummarizer,
        llamaCppBackend: llamaCppSummarizer,
        geminiBackend: geminiAPISummarizer
    )
    private lazy var summaryPipeline = SummaryPipeline(
        captureStore: captureStore,
        summarizationLock: SummarizationLock(),
        backendRouter: backendRouter
    )

    /// The currently selected model ID. "codex" means use Codex CLI;
    /// `google:*` values use hosted Google models through the Gemini API;
    /// other values are llama.cpp model tags (e.g. "qwen3:4b").
    private var activeModel: String = "codex" {
        didSet { saveModel(activeModel) }
    }

    private static let modelDefaultsKey = "MikuExplainsModel"
    private let overlayController = CollapseOverlayWindowController()
    private var statusItem: NSStatusItem?
    private var hotKeyController: HotKeyController?
    private var cachedSummaries: [SummaryRecord] = []
    private var hasLoadedSummaryCache = false
    private var isRefreshingSummaryCache = false
    private var lastCapturedText: String?
    private var shouldRevealCurrentSummary = true
    private var isShowingStreamingResult = false
    private let geminiKeychain = GeminiKeychainCoordinator()
    private static let shortcutDefaultsKey = "MikuExplainsShortcut"

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController.clearDebugLog()

        // Load persisted model selection.
        activeModel = loadModel()

        configureStatusItem()
        configureOverlayCallbacks()
        requestAccessibilityPermission()
        refreshSummaryCache(updateVisibleHistory: false, debugLine: nil)

        let shortcut = loadShortcut()
        overlayController.updateShortcutLabel(shortcut.displayName)
        hotKeyController = HotKeyController(shortcut: shortcut) { [weak self] in
            self?.handleHotKey()
        }

        if let registrationResult = hotKeyController?.register(),
           case .failure(let error) = registrationResult {
            overlayController.showMessage(error.localizedDescription)
        }

        // Reap any orphan llama-server PID and stale pull state from a
        // previous (possibly crashed) run. Cheap when there's nothing to do.
        LlamaCppManager.shared.reapStaleState()
        SummarizationLock().removeStaleLockIfNeeded()

        // Pre-warm the chosen local backend so the first inference doesn't
        // pay the cold-start penalty. llama.cpp's server stays running for
        // the lifetime of the app so the first shortcut is instant.
        if LlamaCppManager.modelRegistry[activeModel] != nil {
            let modelPath = LlamaCppManager.shared.ggufFileURL(for: activeModel)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                overlayController.appendDebugLine("Pre-warming llama-server with \(activeModel)…")
                LlamaCppManager.shared.prewarmServer(modelPath: modelPath) { [weak self] in
                    self?.overlayController.appendDebugLine("llama-server ready.")
                }
            } else {
                overlayController.appendDebugLine("llama.cpp model not installed yet — server will start after pull")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
        LlamaCppManager.shared.stopManagedServer()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIconFactory.mikuIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Miku Explains"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Explain Selection",
            action: #selector(collapseSelectedTextFromMenu),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Past Summaries",
            action: #selector(showHistoryFromMenu),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Request Copy Permission",
            action: #selector(requestAccessibilityPermissionFromMenu),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Miku Explains",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func configureOverlayCallbacks() {
        overlayController.onShortcutSettingsRequested = { [weak self] in
            self?.showShortcutSettings()
        }
        overlayController.onShortcutRecorded = { [weak self] event in
            self?.recordShortcut(event)
        }
        overlayController.onSetModel = { [weak self] model in
            self?.handleSetModel(model)
        }
        overlayController.onSetGeminiAPIKey = { [weak self] apiKey in
            self?.handleSetGeminiAPIKey(apiKey)
        }
        overlayController.onPullModel = { [weak self] model in
            self?.handlePullModel(model)
        }
        overlayController.onDeleteModel = { [weak self] model in
            self?.handleDeleteModel(model)
        }
        overlayController.onExecuteTool = { [weak self] tool in
            self?.handleExecuteTool(tool)
        }
        overlayController.onReady = { [weak self] in
            self?.sendModelsToPanel()
        }
        overlayController.onDismissGeminiKeyWarning = { [weak self] in
            self?.handleGeminiKeychainHeadsUpAcknowledged()
        }
        overlayController.onShowHistory = { [weak self] in
            self?.showHistory()
        }
    }

    @objc private func collapseSelectedTextFromMenu() {
        scheduleCollapseSelectedText()
    }

    @objc private func requestAccessibilityPermissionFromMenu() {
        requestAccessibilityPermission()
    }

    @objc private func showHistoryFromMenu() {
        showHistory()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func requestAccessibilityPermission() {
        _ = textReader.requestTrustIfNeeded()
    }

    private func handleHotKey() {
        if overlayController.isPanelVisible {
            scheduleVisiblePanelShortcutCheck()
            return
        }

        scheduleCollapseSelectedText()
    }

    private func scheduleVisiblePanelShortcutCheck() {
        overlayController.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.handleVisiblePanelShortcut()
        }
    }

    private func handleVisiblePanelShortcut() {
        switch textReader.readSelectedText() {
        case .success(let capture):
            if capture.text == lastCapturedText {
                shouldRevealCurrentSummary = false
                return
            }

            beginPipeline(for: capture, lockAlreadyAcquired: false)
        case .failure(.noSelectedText):
            shouldRevealCurrentSummary = false
        case .failure(let error):
            overlayController.showMessage(error.localizedDescription)
        }
    }

    private func scheduleCollapseSelectedText() {
        switch summaryPipeline.reserveForCapture() {
        case .success:
            break
        case .failure(let error):
            NSLog("Miku Explains summarization lock blocked shortcut: %@", error.localizedDescription)
            overlayController.appendDebugLine("Shortcut ignored: \(error.localizedDescription)")
            if case .alreadyRunning = error, summaryPipeline.isRunning {
                return
            }
            overlayController.showMessage(error.localizedDescription)
            return
        }

        showReadingSelectionPanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.collapseSelectedText()
        }
    }

    private func showReadingSelectionPanel() {
        overlayController.showLoading(
            title: "Reading",
            debug: "Shortcut received.\nReading selected text...",
            onBack: { [weak self] in self?.showHistory() }
        )
    }

    private func collapseSelectedText() {
        switch textReader.readSelectedText() {
        case .success(let capture):
            beginPipeline(for: capture, lockAlreadyAcquired: true)
        case .failure(let error):
            NSLog("Miku Explains capture failed: %@", error.localizedDescription)
            summaryPipeline.releaseReservedCapture()
            showHistory(debugLine: "No copied text found. Showing past results. \(error.localizedDescription)")
        }
    }

    private func beginPipeline(for capture: CapturedText, lockAlreadyAcquired: Bool) {
        if GeminiAPIModelRegistry.isHostedGeminiAPIModel(activeModel) {
            requestGeminiKeyAccess { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .ready:
                    self.continueBeginPipeline(for: capture, lockAlreadyAcquired: lockAlreadyAcquired)
                case .missingKey, .permissionDenied:
                    if lockAlreadyAcquired {
                        self.summaryPipeline.releaseReservedCapture()
                    }
                    self.shouldRevealCurrentSummary = false
                    self.isShowingStreamingResult = false
                    let modelName = GeminiAPIModelRegistry.info(for: self.activeModel)?.displayName ?? "Gemma"
                    switch result {
                    case .missingKey:
                        self.overlayController.showMessage(
                            "Add a Gemini API key in the model menu before using \(modelName)."
                        )
                        self.overlayController.appendDebugLine("Inference blocked: Gemini API key missing for \(self.activeModel).")
                    case .permissionDenied:
                        self.overlayController.showMessage(
                            "Allow Keychain access for Miku Explains before using \(modelName)."
                        )
                        self.overlayController.appendDebugLine("Inference blocked: Gemini Keychain access denied for \(self.activeModel).")
                    case .ready:
                        break
                    }
                }
            }
            return
        }

        continueBeginPipeline(for: capture, lockAlreadyAcquired: lockAlreadyAcquired)
    }

    private func continueBeginPipeline(for capture: CapturedText, lockAlreadyAcquired: Bool) {
        lastCapturedText = capture.text
        shouldRevealCurrentSummary = true
        isShowingStreamingResult = false
        NSLog("Miku Explains captured %d characters via %@", capture.text.count, capture.source.rawValue)
        overlayController.showLoading(
            title: "Summarizing",
            debug: "",
            loadingPhase: GeminiAPIModelRegistry.isHostedGeminiAPIModel(activeModel) ? "hosted" : "local",
            onBack: { [weak self] in self?.showHistory() }
        )
        summaryPipeline.run(
            capture: capture,
            model: activeModel,
            lockAlreadyAcquired: lockAlreadyAcquired,
            events: pipelineEvents()
        )
    }

    private func pipelineEvents() -> SummaryPipelineEvents {
        SummaryPipelineEvents(
            debug: { [weak self] line in
                self?.overlayController.appendDebugLine(line)
            },
            savedCapture: { [weak self] record in
                NSLog("Miku Explains saved capture to %@", record.captureURL.path)
                self?.overlayController.appendDebugLine("Saved capture: \(record.captureURL.path)")
                self?.overlayController.appendDebugLine("Raw output: \(record.rawSummaryURL.path)")
            },
            webSearchStarted: { [weak self] in
                self?.overlayController.showWebSearchLoadingPhase()
            },
            thinkingStarted: { [weak self] in
                guard let self, self.shouldRevealCurrentSummary else {
                    return
                }
                self.isShowingStreamingResult = true
                self.overlayController.showThinkingResult(
                    onBack: { [weak self] in self?.showHistory() }
                )
            },
            partialResult: { [weak self] snapshot in
                guard let self, self.shouldRevealCurrentSummary else {
                    return
                }
                self.isShowingStreamingResult = true
                self.overlayController.showStreamingResult(
                    title: snapshot.title,
                    intent: snapshot.primaryIntent,
                    cards: snapshot.cards,
                    onBack: { [weak self] in self?.showHistory() }
                )
            },
            completed: { [weak self] summary, providerLabel in
                self?.handlePipelineCompleted(summary, providerLabel: providerLabel)
            },
            failed: { [weak self] error, providerLabel in
                self?.handlePipelineFailed(error, providerLabel: providerLabel)
            }
        )
    }

    private func handlePipelineCompleted(_ summary: SummaryRecord, providerLabel: String) {
        NSLog("Miku Explains saved %@ result to %@", providerLabel, summary.summaryURL.path)
        cacheSummary(summary)
        guard shouldRevealCurrentSummary else {
            shouldRevealCurrentSummary = true
            isShowingStreamingResult = false
            return
        }
        if isShowingStreamingResult {
            isShowingStreamingResult = false
            overlayController.showResult(
                title: summary.tagline,
                intent: summary.primaryIntent,
                usedWebSearch: summary.usedWebSearch,
                cards: summary.cards,
                debug: "\(providerLabel) result saved: \(summary.summaryURL.path)",
                onBack: { [weak self] in self?.showHistory() }
            )
            return
        }
        if GeminiAPIModelRegistry.isHostedGeminiAPIModel(activeModel) {
            overlayController.showResult(
                title: summary.tagline,
                intent: summary.primaryIntent,
                usedWebSearch: summary.usedWebSearch,
                cards: summary.cards,
                debug: "\(providerLabel) result saved: \(summary.summaryURL.path)",
                onBack: { [weak self] in self?.showHistory() }
            )
            return
        }
        overlayController.completeLoading {
            self.overlayController.showResult(
                title: summary.tagline,
                intent: summary.primaryIntent,
                usedWebSearch: summary.usedWebSearch,
                cards: summary.cards,
                debug: "\(providerLabel) result saved: \(summary.summaryURL.path)",
                onBack: { [weak self] in self?.showHistory() }
            )
        }
    }

    private func handlePipelineFailed(_ error: CodexSummarizerError, providerLabel: String) {
        NSLog("Miku Explains %@ result failed: %@", providerLabel, error.localizedDescription)
        overlayController.appendDebugLine("\(providerLabel) failed: \(error.localizedDescription)")

        if case .alreadyRunning = error {
            if summaryPipeline.isRunning {
                return
            }
            overlayController.showMessage(error.localizedDescription)
            return
        }

        shouldRevealCurrentSummary = false
        isShowingStreamingResult = false
        overlayController.showMessage(error.localizedDescription)
    }

    private func showHistory(debugLine: String? = nil) {
        let visibleDebugLine = debugLine ?? (hasLoadedSummaryCache ? nil : "Loading results...")
        overlayController.showHistory(
            cachedSummaries,
            debug: visibleDebugLine,
            onSelect: { [weak self] summary in
                self?.showStoredSummary(summary)
            }
        )
        refreshSummaryCache(updateVisibleHistory: true, debugLine: debugLine)
    }

    private func refreshSummaryCache(updateVisibleHistory: Bool, debugLine: String?) {
        guard isRefreshingSummaryCache == false else {
            return
        }

        isRefreshingSummaryCache = true
        Task.detached { [captureStore] in
            let result = Result {
                try captureStore.listSummaries()
            }

            await MainActor.run {
                self.isRefreshingSummaryCache = false

                switch result {
                case .success(let summaries):
                    self.cachedSummaries = summaries
                    self.hasLoadedSummaryCache = true
                    if updateVisibleHistory {
                        self.overlayController.showHistory(
                            summaries,
                            debug: debugLine,
                            onSelect: { [weak self] summary in
                                self?.showStoredSummary(summary)
                            }
                        )
                    }
                case .failure(let error):
                    self.hasLoadedSummaryCache = true
                    if updateVisibleHistory {
                        self.overlayController.showMessage("Could not load results. \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func showStoredSummary(_ summary: SummaryRecord) {
        do {
            let loadedSummary = try captureStore.loadSummary(summary)
            overlayController.showResult(
                title: loadedSummary.tagline,
                intent: loadedSummary.primaryIntent,
                usedWebSearch: loadedSummary.usedWebSearch,
                cards: loadedSummary.cards,
                debug: "Loaded result: \(loadedSummary.summaryURL.path)",
                onBack: { [weak self] in self?.showHistory() }
            )
        } catch {
            overlayController.showMessage("Could not load result. \(error.localizedDescription)")
        }
    }

    private func showShortcutSettings() {
        overlayController.showShortcutSettings()
    }

    private func recordShortcut(_ event: ShortcutKeyboardEvent) {
        do {
            let shortcut = try HotKeyShortcut.fromWebKeyboardEvent(event)
            guard let hotKeyController else {
                return
            }

            switch hotKeyController.updateShortcut(shortcut) {
            case .success:
                saveShortcut(shortcut)
                overlayController.updateShortcutLabel(shortcut.displayName)
                overlayController.showShortcutAccepted(shortcut.displayName)
            case .failure(let error):
                overlayController.showShortcutSettings(error: error.localizedDescription)
            }
        } catch {
            overlayController.showShortcutSettings(error: error.localizedDescription)
        }
    }

    private func loadShortcut() -> HotKeyShortcut {
        guard let data = UserDefaults.standard.data(forKey: Self.shortcutDefaultsKey),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) else {
            return .default
        }

        return shortcut
    }

    private func saveShortcut(_ shortcut: HotKeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.shortcutDefaultsKey)
    }

    private func loadModel() -> String {
        let savedModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? "codex"
        let model = canonicalModelTag(for: savedModel)
        if model != savedModel {
            saveModel(model)
        }

        if model == "codex"
            || LlamaCppManager.modelRegistry[model] != nil
            || GeminiAPIModelRegistry.isHostedGeminiAPIModel(model) {
            return model
        }

        return "codex"
    }

    private func saveModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey)
    }

    private func sendModelsToPanel() {
        let selected = activeModel
        let isHostedGemini = GeminiAPIModelRegistry.isHostedGeminiAPIModel(selected)
        let geminiKeyConfigured = geminiKeychain.panelKeyConfigured(isGemmaSelected: isHostedGemini)
        let warning = geminiKeychain.isHeadsUpVisible

        LlamaCppManager.shared.listInstalledModels { [weak self] models in
            guard let self else {
                return
            }

            let configuredLabel = geminiKeyConfigured.map { $0 ? "true" : "false" } ?? "nil"
            self.overlayController.appendDebugLine(
                "Gemini panel sync: selected=\(selected) geminiAPIKeyConfigured=\(configuredLabel) geminiKeyWarning=\(warning) \(self.geminiKeychain.debugSnapshot())"
            )
            self.overlayController.sendModels(
                models,
                selected: selected,
                localBackendAvailable: true,
                modelCatalog: LlamaCppManager.shared.modelCatalog(),
                geminiAPIKeyConfigured: geminiKeyConfigured,
                geminiKeyWarning: warning
            )
        }
    }

    private func requestGeminiKeyAccess(completion: @escaping (GeminiKeyAccessResult) -> Void) {
        geminiKeychain.requestAccess(
            presentHeadsUp: { [weak self] in
                guard let self else {
                    return
                }
                self.overlayController.presentGeminiKeychainConsentPrompt(selectedModel: self.activeModel)
                self.sendModelsToPanel()
            },
            log: { [weak self] line in
                self?.overlayController.appendDebugLine(line)
            },
            completion: completion
        )
    }

    private func handleGeminiKeychainHeadsUpAcknowledged() {
        let result = geminiKeychain.acknowledgeHeadsUp { [weak self] line in
            self?.overlayController.appendDebugLine(line)
        }
        overlayController.setGeminiKeyWarning(false)
        overlayController.restorePanelWindowLevel()

        switch result {
        case .ready:
            break
        case .missingKey:
            overlayController.appendDebugLine("No Gemini API key stored yet; paste one in the model menu.")
        case .permissionDenied:
            overlayController.showToolMessage("Could not unlock the Gemini API key from Keychain.")
        }

        sendModelsToPanel()
    }

    private func handleSetModel(_ model: String) {
        let canonicalModel = canonicalModelTag(for: model)
        guard canonicalModel == "codex"
            || LlamaCppManager.modelRegistry[canonicalModel] != nil
            || GeminiAPIModelRegistry.isHostedGeminiAPIModel(canonicalModel) else {
            overlayController.showMessage("Unknown model: \(canonicalModel)")
            overlayController.appendDebugLine("Model switch ignored: unknown model \(canonicalModel)")
            return
        }

        activeModel = canonicalModel
        if let info = GeminiAPIModelRegistry.info(for: canonicalModel) {
            overlayController.appendDebugLine("Switched to Google Gemini API model: \(info.displayName)")
            requestGeminiKeyAccess { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .ready:
                    break
                case .missingKey:
                    self.overlayController.appendDebugLine("Gemini API key missing; add one in the model menu before using \(info.displayName).")
                case .permissionDenied:
                    self.overlayController.showToolMessage("Could not unlock the Gemini API key from Keychain.")
                }
                self.sendModelsToPanel()
            }
        } else if canonicalModel != "codex" {
            overlayController.appendDebugLine("Switched to llama.cpp model: \(canonicalModel)")
            let modelPath = LlamaCppManager.shared.ggufFileURL(for: canonicalModel)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                overlayController.appendDebugLine("Pre-warming llama-server with \(canonicalModel)…")
                LlamaCppManager.shared.prewarmServer(modelPath: modelPath) { [weak self] in
                    self?.overlayController.appendDebugLine("llama-server ready.")
                }
            } else {
                overlayController.appendDebugLine("Model not installed yet — pull it first")
            }
            sendModelsToPanel()
        } else {
            sendModelsToPanel()
        }
    }

    private func handleSetGeminiAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try GeminiAPIKeyStore.shared.save(apiKey)
            if trimmed.isEmpty {
                overlayController.appendDebugLine("Gemini API key cleared from Keychain.")
                overlayController.showToolMessage("Gemini API key cleared.")
                sendModelsToPanel()
                return
            }

            overlayController.appendDebugLine("Gemini API key saved to Keychain.")
            overlayController.showToolMessage("Gemini API key saved.")
            requestGeminiKeyAccess { [weak self] result in
                guard let self else {
                    return
                }
                if case .permissionDenied = result {
                    self.overlayController.showToolMessage("Could not unlock the Gemini API key from Keychain.")
                }
                self.sendModelsToPanel()
            }
        } catch {
            overlayController.appendDebugLine("Gemini API key save failed: \(error.localizedDescription)")
            overlayController.showToolMessage(error.localizedDescription)
        }
    }

    private var activePullModel: String?

    private func handlePullModel(_ model: String) {
        let canonicalModel = canonicalModelTag(for: model)
        guard LlamaCppManager.modelRegistry[canonicalModel] != nil else {
            overlayController.showMessage("Unknown local model: \(canonicalModel)")
            overlayController.appendDebugLine("Pull ignored: unknown llama.cpp model \(canonicalModel)")
            return
        }

        guard activePullModel == nil else {
            overlayController.appendDebugLine("Pull ignored: already pulling \(activePullModel!)")
            return
        }
        activePullModel = canonicalModel
        overlayController.appendDebugLine("Pull started: \(canonicalModel)")

        handlePullModelLlamaCpp(canonicalModel)
    }

    private func handleDeleteModel(_ model: String) {
        let canonicalModel = canonicalModelTag(for: model)
        guard LlamaCppManager.modelRegistry[canonicalModel] != nil else {
            overlayController.showMessage("Unknown local model: \(canonicalModel)")
            overlayController.appendDebugLine("Delete ignored: unknown llama.cpp model \(canonicalModel)")
            return
        }

        guard activePullModel == nil else {
            overlayController.appendDebugLine("Delete ignored: pull in progress for \(activePullModel!)")
            return
        }

        switch LlamaCppManager.shared.deleteInstalledModel(canonicalModel) {
        case .success:
            overlayController.appendDebugLine("Deleted local model: \(canonicalModel)")
            overlayController.showToolMessage("Deleted \(LlamaCppManager.modelRegistry[canonicalModel]?.displayName ?? canonicalModel).")
            if activeModel == canonicalModel {
                activeModel = "codex"
                overlayController.appendDebugLine("Switched to Codex after deleting the active local model.")
            }
            sendModelsToPanel()
        case .failure(let error):
            overlayController.appendDebugLine("Delete failed: \(canonicalModel) — \(error.localizedDescription)")
            overlayController.showToolMessage(error.localizedDescription)
        }
    }

    private func canonicalModelTag(for model: String) -> String {
        GeminiAPIModelRegistry.canonicalModelTag(
            for: LlamaCppManager.canonicalModelTag(for: model)
        )
    }

    private func handlePullModelLlamaCpp(_ model: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Step 1: ensure llama-server binary is installed.
            let installSem = DispatchSemaphore(value: 0)
            let installBox = UnsafeMutableTransfer<LlamaCppError?>(nil)
            LlamaCppManager.shared.ensureServerBinaryInstalled(
                progress: { [weak self] msg in
                    self?.overlayController.appendDebugLine("llama.cpp install: \(msg)")
                    self?.overlayController.updateModelPull(
                        model: model, progress: 0.0, done: false, error: nil, statusText: "Preparing"
                    )
                },
                completion: { result in
                    if case .failure(let e) = result { installBox.value = e }
                    installSem.signal()
                }
            )
            installSem.wait()

            if let err = installBox.value {
                Task { @MainActor [weak self] in
                    let msg = "llama.cpp install failed: \(err.localizedDescription)"
                    self?.overlayController.appendDebugLine(msg)
                    self?.overlayController.updateModelPull(
                        model: model, progress: 0, done: true, error: msg
                    )
                    self?.activePullModel = nil
                }
                return
            }

            // Step 2: download the GGUF. The server isn't needed for the
            // download — it's started lazily on first inference.
            LlamaCppManager.shared.pullModel(
                model,
                progress: { [weak self] ratio, statusText in
                    self?.overlayController.updateModelPull(
                        model: model, progress: ratio, done: false, error: nil, statusText: statusText
                    )
                },
                completion: { [weak self] result in
                    switch result {
                    case .success:
                        self?.overlayController.appendDebugLine("Pull complete: \(model)")
                        self?.overlayController.updateModelPull(
                            model: model, progress: 1.0, done: true, error: nil
                        )
                        self?.activePullModel = nil
                        self?.handleSetModel(model)
                    case .failure(let error):
                        let msg = error.localizedDescription
                        self?.overlayController.appendDebugLine("Pull failed: \(model) — \(msg)")
                        self?.overlayController.updateModelPull(
                            model: model, progress: 0, done: true, error: msg
                        )
                        self?.activePullModel = nil
                    }
                }
            )
        }
    }

    private func handleExecuteTool(_ tool: AIResultTool) {
        overlayController.appendDebugLine("Tool requested: \(tool.name)")
        overlayController.showToolMessage("Working...")
        toolExecutor.execute(tool) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let message):
                self.overlayController.appendDebugLine("Tool success: \(message)")
                self.overlayController.showToolMessage(message)
            case .failure(let error):
                let message = error.localizedDescription
                self.overlayController.appendDebugLine("Tool failed: \(message)")
                self.overlayController.showToolMessage(message)
            }
        }
    }

    // MARK: - Caching

    private func cacheSummary(_ summary: SummaryRecord) {
        cachedSummaries.removeAll { $0.summaryURL == summary.summaryURL }
        cachedSummaries.insert(summary, at: 0)
        cachedSummaries.sort { $0.timestamp > $1.timestamp }
        hasLoadedSummaryCache = true
    }
}
