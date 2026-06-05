import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let textReader = SelectedTextReader()
    private let captureStore = CaptureStore()
    private let summarizationLock = SummarizationLock()
    private lazy var codexSummarizer = CodexSummarizer(captureStore: captureStore)
    private lazy var ollamaSummarizer = OllamaSummarizer(captureStore: captureStore)

    /// The currently selected model ID. "codex" means use Codex CLI;
    /// any other value is an Ollama model tag (e.g. "qwen3:4b").
    private var activeModel: String = "codex" {
        didSet { saveModel(activeModel) }
    }

    private static let modelDefaultsKey = "MikuExplainsModel"
    private let overlayController = CollapseOverlayWindowController()
    private var statusItem: NSStatusItem?
    private var hotKeyController: HotKeyController?
    private var activeLockToken: SummarizationLockToken?
    private var cachedSummaries: [SummaryRecord] = []
    private var hasLoadedSummaryCache = false
    private var isRefreshingSummaryCache = false
    private var lastCapturedText: String?
    private var shouldRevealCurrentSummary = true
    private static let shortcutDefaultsKey = "MikuExplainsShortcut"

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Start Ollama server in the background so the first inference
        // doesn't pay the cold-start penalty. The daemon is ~50 MB with
        // no model loaded; the model only loads on the first request and
        // unloads after 5 min idle.
        if activeModel != "codex" {
            DispatchQueue.global(qos: .background).async {
                OllamaManager.shared.ensureServerRunning()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
        OllamaManager.shared.stopManagedServer()
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
        overlayController.onPullModel = { [weak self] model in
            self?.handlePullModel(model)
        }
        overlayController.onReady = { [weak self] in
            self?.sendModelsToPanel()
        }
    }

    @objc private func collapseSelectedTextFromMenu() {
        scheduleCollapseSelectedText()
    }

    @objc private func requestAccessibilityPermissionFromMenu() {
        requestAccessibilityPermission()
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
        guard acquireSummarizationLock() else {
            return
        }

        overlayController.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.collapseSelectedText()
        }
    }

    private func collapseSelectedText() {
        switch textReader.readSelectedText() {
        case .success(let capture):
            beginPipeline(for: capture, lockAlreadyAcquired: true)
        case .failure(let error):
            NSLog("Miku Explains capture failed: %@", error.localizedDescription)
            releaseSummarizationLock()
            showHistory(debugLine: "No copied text found. Showing past results. \(error.localizedDescription)")
        }
    }

    private func beginPipeline(for capture: CapturedText, lockAlreadyAcquired: Bool) {
        guard lockAlreadyAcquired || acquireSummarizationLock() else {
            return
        }

        lastCapturedText = capture.text
        shouldRevealCurrentSummary = true
        let initialDebug = """
        Capture source: \(capture.source.rawValue)
        Captured characters: \(capture.text.count)
        Saving capture...
        """
        NSLog("Miku Explains captured %d characters via %@", capture.text.count, capture.source.rawValue)
        overlayController.showLoading(
            title: "Summarizing",
            debug: initialDebug,
            onBack: { [weak self] in self?.showHistory() }
        )
        saveCaptureAndSummarize(capture.text)
    }

    private func saveCaptureAndSummarize(_ text: String) {
        do {
            let record = try captureStore.save(text)
            NSLog("Miku Explains saved capture to %@", record.captureURL.path)
            overlayController.appendDebugLine("Saved capture: \(record.captureURL.path)")
            overlayController.appendDebugLine("Raw Codex output: \(record.rawSummaryURL.path)")
            overlayController.appendDebugLine("Launching Codex CLI...")
            summarize(record)
        } catch {
            NSLog("Miku Explains failed to save capture: %@", error.localizedDescription)
            overlayController.appendDebugLine("Save failed: \(error.localizedDescription)")
            releaseSummarizationLock()
        }
    }

    private func summarize(_ record: CaptureRecord) {
        if activeModel == "codex" {
            summarizeWithCodex(record)
        } else {
            summarizeWithOllama(record, model: activeModel)
        }
    }

    private func summarizeWithCodex(_ record: CaptureRecord) {
        codexSummarizer.summarize(
            record: record,
            onProcessStarted: { [weak self] processIdentifier in
                self?.markSummarizationLockProcess(processIdentifier)
                self?.overlayController.appendDebugLine("Codex PID: \(processIdentifier)")
            },
            onWebSearchStarted: { [weak self] in
                self?.overlayController.showWebSearchLoadingPhase()
                self?.overlayController.appendDebugLine("Entering web search verification phase...")
            }
        ) { result in
            self.handleSummaryResult(result, providerLabel: "Codex")
        }
    }

    private func summarizeWithOllama(_ record: CaptureRecord, model: String) {
        overlayController.appendDebugLine("Ollama model: \(model)")
        ollamaSummarizer.summarize(
            record: record,
            model: model,
            onProcessStarted: { [weak self] _ in
                self?.markSummarizationLockProcess(0)
                self?.overlayController.appendDebugLine("Ollama request sent")
            },
            onWebSearchStarted: { }
        ) { result in
            self.handleSummaryResult(result, providerLabel: "Ollama/\(model)")
        }
    }

    private func handleSummaryResult(
        _ result: Result<SummaryRecord, CodexSummarizerError>,
        providerLabel: String
    ) {
        releaseSummarizationLock()

        switch result {
        case .success(let summary):
            NSLog("Miku Explains saved %@ result to %@", providerLabel, summary.summaryURL.path)
            cacheSummary(summary)
            guard shouldRevealCurrentSummary else {
                shouldRevealCurrentSummary = true
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
        case .failure(let error):
            NSLog("Miku Explains %@ result failed: %@", providerLabel, error.localizedDescription)
            overlayController.appendDebugLine("\(providerLabel) failed: \(error.localizedDescription)")
        }
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
        UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? "codex"
    }

    private func saveModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey)
    }

    private func sendModelsToPanel() {
        let selected = activeModel
        let available = OllamaManager.shared.isOllamaInstalled
        if available {
            OllamaManager.shared.listInstalledModels { [weak self] models in
                self?.overlayController.sendModels(models, selected: selected, ollamaAvailable: true)
            }
        } else {
            overlayController.sendModels([], selected: selected, ollamaAvailable: false)
        }
    }

    private func handleSetModel(_ model: String) {
        activeModel = model
        if model != "codex" {
            overlayController.appendDebugLine("Switched to Ollama model: \(model)")
            DispatchQueue.global(qos: .background).async {
                OllamaManager.shared.ensureServerRunning()
            }
        }
        sendModelsToPanel()
    }

    private var activePullModel: String?

    private func handlePullModel(_ model: String) {
        guard activePullModel == nil else {
            overlayController.appendDebugLine("Pull ignored: already pulling \(activePullModel!)")
            return
        }
        activePullModel = model
        overlayController.appendDebugLine("Pull started: \(model)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Step 1: ensure ollama binary exists, downloading it if needed.
            let installSem = DispatchSemaphore(value: 0)
            let installBox = UnsafeMutableTransfer<Error?>(nil)
            OllamaManager.shared.ensureOllamaInstalled(
                progress: { [weak self] msg in
                    self?.overlayController.appendDebugLine("Ollama install: \(msg)")
                    self?.overlayController.updateModelPull(
                        model: model, progress: 0.0, done: false, error: nil, statusText: msg
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
                    let msg = "Ollama install failed: \(err.localizedDescription)"
                    self?.overlayController.appendDebugLine(msg)
                    self?.overlayController.updateModelPull(
                        model: model, progress: 0, done: true, error: msg
                    )
                    self?.activePullModel = nil
                }
                return
            }

            Task { @MainActor [weak self] in
                self?.overlayController.appendDebugLine("Ollama ready, starting server…")
            }

            // Step 2: ensure server is running.
            let serverUp = OllamaManager.shared.ensureServerRunning()
            guard serverUp else {
                Task { @MainActor [weak self] in
                    let home = ProcessInfo.processInfo.environment["HOME"] ?? "?"
                    let binaryExists = FileManager.default.fileExists(atPath: "\(home)/.ollama/bin/ollama")
                    let msg = "Ollama server failed to start. Binary at ~/.ollama/bin/ollama: \(binaryExists ? "exists" : "MISSING")"
                    self?.overlayController.appendDebugLine(msg)
                    self?.overlayController.updateModelPull(model: model, progress: 0, done: true, error: msg)
                    self?.activePullModel = nil
                }
                return
            }

            Task { @MainActor [weak self] in
                self?.overlayController.appendDebugLine("Server up, pulling \(model)…")
            }

            // Step 3: pull the model.
            OllamaManager.shared.pullModel(
                model,
                progress: { [weak self] ratio in
                    self?.overlayController.updateModelPull(
                        model: model, progress: ratio, done: false, error: nil
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

    private func cacheSummary(_ summary: SummaryRecord) {        cachedSummaries.removeAll { $0.summaryURL == summary.summaryURL }
        cachedSummaries.insert(summary, at: 0)
        cachedSummaries.sort { $0.timestamp > $1.timestamp }
        hasLoadedSummaryCache = true
    }

    private func acquireSummarizationLock() -> Bool {
        guard activeLockToken == nil else {
            overlayController.showMessage("Already summarizing. Wait for the current summary to finish.")
            overlayController.appendDebugLine("Shortcut ignored: in-memory summarization lock is active.")
            return false
        }

        do {
            activeLockToken = try summarizationLock.acquire()
            return true
        } catch {
            NSLog("Miku Explains summarization lock blocked shortcut: %@", error.localizedDescription)
            overlayController.showMessage(error.localizedDescription)
            overlayController.appendDebugLine("Shortcut ignored: \(error.localizedDescription)")
            return false
        }
    }

    private func releaseSummarizationLock() {
        guard let activeLockToken else {
            return
        }

        summarizationLock.release(activeLockToken)
        self.activeLockToken = nil
    }

    private func markSummarizationLockProcess(_ processIdentifier: Int32) {
        guard let activeLockToken else {
            return
        }

        summarizationLock.updateProcessIdentifier(processIdentifier, for: activeLockToken)
    }
}
