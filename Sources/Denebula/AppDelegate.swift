import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let textReader = SelectedTextReader()
    private let captureStore = CaptureStore()
    private let summarizationLock = SummarizationLock()
    private lazy var codexSummarizer = CodexSummarizer(captureStore: captureStore)
    private let overlayController = CollapseOverlayWindowController()
    private var statusItem: NSStatusItem?
    private var hotKeyController: HotKeyController?
    private var activeLockToken: SummarizationLockToken?
    private var cachedSummaries: [SummaryRecord] = []
    private var hasLoadedSummaryCache = false
    private var isRefreshingSummaryCache = false
    private static let shortcutDefaultsKey = "MikuExplainsShortcut"

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
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
            overlayController.hide()
            return
        }

        scheduleCollapseSelectedText()
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
            let initialDebug = """
            Capture source: \(capture.source.rawValue)
            Captured characters: \(capture.text.count)
            Saving capture...
            """
            NSLog("Denebula captured %d characters via %@", capture.text.count, capture.source.rawValue)
            overlayController.showLoading(
                title: "Summarizing",
                debug: initialDebug,
                onBack: { [weak self] in self?.showHistory() }
            )
            saveCaptureAndSummarize(capture.text)
        case .failure(let error):
            NSLog("Denebula capture failed: %@", error.localizedDescription)
            releaseSummarizationLock()
            showHistory(debugLine: "No copied text found. Showing past results. \(error.localizedDescription)")
        }
    }

    private func saveCaptureAndSummarize(_ text: String) {
        do {
            let record = try captureStore.save(text)
            NSLog("Denebula saved capture to %@", record.captureURL.path)
            overlayController.appendDebugLine("Saved capture: \(record.captureURL.path)")
            overlayController.appendDebugLine("Raw Codex output: \(record.rawSummaryURL.path)")
            overlayController.appendDebugLine("Launching Codex CLI...")
            summarize(record)
        } catch {
            NSLog("Denebula failed to save capture: %@", error.localizedDescription)
            overlayController.appendDebugLine("Save failed: \(error.localizedDescription)")
            releaseSummarizationLock()
        }
    }

    private func summarize(_ record: CaptureRecord) {
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
            self.releaseSummarizationLock()

            switch result {
            case .success(let summary):
                NSLog("Denebula saved Codex result to %@", summary.summaryURL.path)
                self.cacheSummary(summary)
                self.overlayController.completeLoading {
                    self.overlayController.showResult(
                        title: summary.tagline,
                        intent: summary.primaryIntent,
                        usedWebSearch: summary.usedWebSearch,
                        cards: summary.cards,
                        debug: "Codex result saved: \(summary.summaryURL.path)",
                        onBack: { [weak self] in self?.showHistory() }
                    )
                }
            case .failure(let error):
                NSLog("Denebula Codex result failed: %@", error.localizedDescription)
                self.overlayController.appendDebugLine("Codex result failed: \(error.localizedDescription)")
            }
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

    private func cacheSummary(_ summary: SummaryRecord) {
        cachedSummaries.removeAll { $0.summaryURL == summary.summaryURL }
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
            NSLog("Denebula summarization lock blocked shortcut: %@", error.localizedDescription)
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
