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

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        requestAccessibilityPermission()
        refreshSummaryCache(updateVisibleHistory: false, debugLine: nil)

        hotKeyController = HotKeyController { [weak self] in
            self?.scheduleCollapseSelectedText()
        }
        hotKeyController?.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIconFactory.blackHoleIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Denebula"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Collapse Selection",
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
            title: "Quit Denebula",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
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
            showHistory(debugLine: "No copied text found. Showing past summaries. \(error.localizedDescription)")
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
            }
        ) { result in
            self.releaseSummarizationLock()

            switch result {
            case .success(let summary):
                NSLog("Denebula saved Codex summary to %@", summary.summaryURL.path)
                self.cacheSummary(summary)
                self.overlayController.completeLoading {
                    self.overlayController.showSummary(
                        title: summary.tagline,
                        summary: summary.summary,
                        validity: summary.validityAnalysis,
                        debug: "Codex summary saved: \(summary.summaryURL.path)",
                        onBack: { [weak self] in self?.showHistory() }
                    )
                }
            case .failure(let error):
                NSLog("Denebula Codex summary failed: %@", error.localizedDescription)
                self.overlayController.appendDebugLine("Codex summary failed: \(error.localizedDescription)")
            }
        }
    }

    private func showHistory(debugLine: String? = nil) {
        let visibleDebugLine = debugLine ?? (hasLoadedSummaryCache ? nil : "Loading summaries...")
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
                        self.overlayController.showMessage("Could not load summaries. \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func showStoredSummary(_ summary: SummaryRecord) {
        do {
            let loadedSummary = try captureStore.loadSummary(summary)
            overlayController.showSummary(
                title: loadedSummary.tagline,
                summary: loadedSummary.summary,
                validity: loadedSummary.validityAnalysis,
                debug: "Loaded summary: \(loadedSummary.summaryURL.path)",
                onBack: { [weak self] in self?.showHistory() }
            )
        } catch {
            overlayController.showMessage("Could not load summary. \(error.localizedDescription)")
        }
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
