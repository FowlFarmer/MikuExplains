import AppKit
import WebKit

final class CollapseOverlayWindowController: NSWindowController {
    private let contentView = WebPanelView()
    private static let panelSize = NSSize(width: 570, height: 620)
    private static let panelRightMargin: CGFloat = 40
    private static let panelTopMargin: CGFloat = 14
    private static let panelBottomMargin: CGFloat = 40
    var onShortcutSettingsRequested: (() -> Void)?
    var onShortcutRecorded: ((ShortcutKeyboardEvent) -> Void)?

    init() {
        let window = CollapsePanelWindow(
            contentRect: Self.panelFrame(on: Self.preferredScreen()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.minSize = Self.panelSize
        window.maxSize = Self.panelSize
        window.contentView = contentView

        super.init(window: window)

        contentView.onClose = { [weak self] in
            self?.hide()
        }
        contentView.onOpenShortcutSettings = { [weak self] in
            self?.onShortcutSettingsRequested?()
        }
        contentView.onRecordShortcut = { [weak self] event in
            self?.onShortcutRecorded?(event)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(title: String, debug: String, onBack: @escaping () -> Void) {
        contentView.showLoading(title: title, debug: debug, onBack: onBack)
        showPanel()
    }

    func completeLoading(completion: @escaping @MainActor () -> Void) {
        contentView.completeLoading(completion: completion)
    }

    func showWebSearchLoadingPhase() {
        contentView.showWebSearchLoadingPhase()
    }

    func showResult(title: String, intent: String, usedWebSearch: Bool, cards: [AIResultCard], debug: String, onBack: @escaping () -> Void) {
        contentView.showResult(
            title: title,
            intent: intent,
            usedWebSearch: usedWebSearch,
            cards: cards,
            debug: debug,
            onBack: onBack
        )
        showPanel()
    }

    func showHistory(_ summaries: [SummaryRecord], debug: String?, onSelect: @escaping (SummaryRecord) -> Void) {
        contentView.showHistory(summaries, debug: debug, onSelect: onSelect)
        showPanel()
    }

    func showMessage(_ message: String) {
        contentView.showMessage(message)
        showPanel()
    }

    func showShortcutSettings(error: String? = nil) {
        contentView.showShortcutSettings(error: error)
        showPanel()
    }

    func showShortcutAccepted(_ label: String) {
        contentView.showShortcutAccepted(label)
        showPanel()
    }

    func updateShortcutLabel(_ label: String) {
        contentView.updateShortcutLabel(label)
    }

    func appendDebugLine(_ line: String) {
        contentView.appendDebugLine(line)
    }

    var isPanelVisible: Bool {
        window?.isVisible ?? false
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func showPanel() {
        guard let window else {
            return
        }

        let wasVisible = window.isVisible
        window.setContentSize(Self.panelSize)
        let targetFrame = Self.panelFrame(on: Self.preferredScreen())
        window.setFrame(targetFrame, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: Self.panelSize)
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrame(targetFrame, display: false)

        if wasVisible {
            window.alphaValue = 1
            window.displayIfNeeded()
        } else {
            window.alphaValue = 0
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window.animator().alphaValue = 1
            }
        }
    }

    private static func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.visibleFrame.contains(mouseLocation)
        } ?? NSScreen.main
    }

    private static func panelFrame(on screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minX = visibleFrame.minX + panelRightMargin
        let maxX = visibleFrame.maxX - panelSize.width - panelRightMargin
        let minY = visibleFrame.minY + panelBottomMargin
        let maxY = visibleFrame.maxY - panelSize.height - panelTopMargin
        let x = maxX >= minX ? maxX : minX
        let y = maxY >= minY ? maxY : minY

        return NSRect(
            x: x,
            y: y,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

private final class CollapsePanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class WebPanelView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var webViewReady = false
    private var state = WebPanelState.initial
    private var historyRecordsByID: [String: SummaryRecord] = [:]
    private var stateBeforeShortcut: WebPanelState?
    private var onBack: (() -> Void)?
    private var onSelectHistoryItem: ((SummaryRecord) -> Void)?
    var onClose: (() -> Void)?
    var onOpenShortcutSettings: (() -> Void)?
    var onRecordShortcut: ((ShortcutKeyboardEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = TransparentWKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        contentController.add(self, name: "mikuPanel")
        configureWebView()
        loadWebUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(title: String, debug: String, onBack: @escaping () -> Void) {
        self.onBack = onBack
        state = state.replacing(
            view: "loading",
            title: title,
            status: "",
            subtitle: "Reading selection",
            loadingPhase: "local",
            debug: debug,
            items: [],
            summaries: nil
        )
        sendState()
    }

    func showWebSearchLoadingPhase() {
        state = state.replacing(
            view: "loading",
            title: "Verifying",
            status: "web",
            subtitle: "Searching web",
            loadingPhase: "web"
        )
        sendState()
    }

    func completeLoading(completion: @escaping @MainActor () -> Void) {
        state = state.replacing(loadingCompleteToken: state.loadingCompleteToken + 1)
        sendState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            completion()
        }
    }

    func showResult(title: String, intent: String, usedWebSearch: Bool, cards: [AIResultCard], debug: String, onBack: @escaping () -> Void) {
        self.onBack = onBack
        state = state.replacing(
            view: "result",
            title: title.isEmpty ? "Result" : title,
            status: usedWebSearch ? "web" : formattedIntent(intent),
            subtitle: "",
            loadingPhase: "local",
            debug: debug,
            items: cards.map(WebPanelItem.init(card:)),
            summaries: nil
        )
        sendState()
    }

    func showHistory(_ summaries: [SummaryRecord], debug: String?, onSelect: @escaping (SummaryRecord) -> Void) {
        onBack = nil
        onSelectHistoryItem = onSelect
        historyRecordsByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.summaryURL.path, $0) })
        state = state.replacing(
            view: "history",
            title: "Past Results",
            status: "\(summaries.count) saved",
            subtitle: "Past things Miku explained",
            loadingPhase: "local",
            debug: debug ?? "History loaded from Application Support.",
            items: [],
            summaries: summaries.map(WebPanelSummary.init(record:))
        )
        sendState()
    }

    func showMessage(_ message: String) {
        onBack = nil
        state = state.replacing(
            view: "message",
            title: "Miku Explains",
            status: "notice",
            subtitle: "",
            loadingPhase: "local",
            debug: "",
            items: [
                WebPanelItem(
                    type: "note",
                    title: "Note",
                    body: message,
                    confidence: nil
                )
            ],
            summaries: nil
        )
        sendState()
    }

    func showShortcutSettings(error: String? = nil) {
        if state.view != "shortcut" {
            stateBeforeShortcut = state
        }

        state = state.replacing(
            view: "shortcut",
            title: "Shortcut",
            status: "",
            subtitle: "Press a new key combo",
            loadingPhase: "local",
            shortcutError: error ?? "",
            items: [],
            summaries: nil
        )
        sendState()
    }

    func showShortcutAccepted(_ label: String) {
        state = state.replacing(
            view: "shortcut",
            title: "Shortcut set",
            status: "",
            subtitle: label,
            shortcutError: ""
        )
        sendState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { [weak self] in
            self?.restoreStateBeforeShortcut()
        }
    }

    func updateShortcutLabel(_ label: String) {
        state = state.replacing(shortcutLabel: label)
        sendState()
    }

    func appendDebugLine(_ line: String) {
        let existingText = state.debug.trimmingCharacters(in: .whitespacesAndNewlines)
        let debug = existingText.isEmpty ? line : "\(existingText)\n\(line)"
        state = state.replacing(debug: debug)
        sendState()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mikuPanel",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            webViewReady = true
            sendState()
        case "close":
            onClose?()
        case "back":
            if state.view == "shortcut" {
                restoreStateBeforeShortcut()
            } else {
                onBack?()
            }
        case "openShortcutSettings":
            onOpenShortcutSettings?()
        case "recordShortcut":
            guard let code = body["code"] as? String else {
                return
            }

            onRecordShortcut?(
                ShortcutKeyboardEvent(
                    code: code,
                    controlKey: body["controlKey"] as? Bool ?? false,
                    altKey: body["altKey"] as? Bool ?? false,
                    shiftKey: body["shiftKey"] as? Bool ?? false,
                    metaKey: body["metaKey"] as? Bool ?? false
                )
            )
        case "toggleDebug":
            state = state.replacing(debugVisible: !state.debugVisible)
            sendState()
        case "selectHistory":
            guard let id = body["id"] as? String,
                  let record = historyRecordsByID[id] else {
                return
            }
            onSelectHistoryItem?(record)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewReady = true
        makeTransparent(webView)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.makeTransparent(self.webView)
        }
        sendState()
    }

    private func configureWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
        webView.underPageBackgroundColor = .clear
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeTransparent(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false

        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
        }

        view.subviews.forEach(makeTransparent)
    }

    private func loadWebUI() {
        guard let webUIURL = webUIURL() else {
            state = state.replacing(
                view: "message",
                title: "Miku Explains",
                status: "error",
                items: [
                    WebPanelItem(
                        type: "note",
                        title: "Missing Web UI",
                        body: "Could not find bundled React UI resources.",
                        confidence: nil
                    )
                ]
            )
            return
        }

        let readAccessURL = webUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        webView.loadFileURL(webUIURL, allowingReadAccessTo: readAccessURL)
    }

    private func webUIURL() -> URL? {
        if let bundledURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebUI"
        ) {
            return bundledURL
        }

        let fallbackURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("WebUI")
            .appendingPathComponent("index.html")

        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    private func sendState() {
        guard webViewReady,
              let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let script = "window.MikuPanel && window.MikuPanel.setState(\(json));"
        webView.evaluateJavaScript(script)
    }

    private func restoreStateBeforeShortcut() {
        guard let stateBeforeShortcut else {
            state = state.replacing(
                view: "message",
                title: "Miku Explains",
                status: "ready",
                subtitle: "",
                shortcutError: ""
            )
            sendState()
            return
        }

        let shortcutLabel = state.shortcutLabel
        let debugVisible = state.debugVisible
        state = stateBeforeShortcut.replacing(
            debugVisible: debugVisible,
            shortcutLabel: shortcutLabel,
            shortcutError: ""
        )
        self.stateBeforeShortcut = nil
        sendState()
    }

    private func formattedIntent(_ intent: String) -> String {
        intent
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .prefix(2)
            .joined(separator: " ")
    }
}

private final class TransparentWKWebView: WKWebView {
    override var isOpaque: Bool {
        false
    }
}

private struct WebPanelState: Encodable {
    let view: String
    let title: String
    let status: String
    let subtitle: String
    let loadingPhase: String
    let loadingCompleteToken: Int
    let debug: String
    let debugVisible: Bool
    let shortcutLabel: String
    let shortcutError: String
    let items: [WebPanelItem]
    let summaries: [WebPanelSummary]

    static let initial = WebPanelState(
        view: "message",
        title: "Miku Explains",
        status: "ready",
        subtitle: "",
        loadingPhase: "local",
        loadingCompleteToken: 0,
        debug: "",
        debugVisible: false,
        shortcutLabel: HotKeyShortcut.default.displayName,
        shortcutError: "",
        items: [
            WebPanelItem(
                type: "note",
                title: "Ready",
                body: "Highlight text and press the shortcut.",
                confidence: nil
            )
        ],
        summaries: []
    )

    func replacing(
        view: String? = nil,
        title: String? = nil,
        status: String? = nil,
        subtitle: String? = nil,
        loadingPhase: String? = nil,
        loadingCompleteToken: Int? = nil,
        debug: String? = nil,
        debugVisible: Bool? = nil,
        shortcutLabel: String? = nil,
        shortcutError: String? = nil,
        items: [WebPanelItem]? = nil,
        summaries: [WebPanelSummary]? = nil
    ) -> WebPanelState {
        WebPanelState(
            view: view ?? self.view,
            title: title ?? self.title,
            status: status ?? self.status,
            subtitle: subtitle ?? self.subtitle,
            loadingPhase: loadingPhase ?? self.loadingPhase,
            loadingCompleteToken: loadingCompleteToken ?? self.loadingCompleteToken,
            debug: debug ?? self.debug,
            debugVisible: debugVisible ?? self.debugVisible,
            shortcutLabel: shortcutLabel ?? self.shortcutLabel,
            shortcutError: shortcutError ?? self.shortcutError,
            items: items ?? self.items,
            summaries: summaries ?? self.summaries
        )
    }
}

private struct WebPanelItem: Encodable {
    let type: String
    let title: String
    let body: String
    let confidence: String?

    init(type: String, title: String, body: String, confidence: String?) {
        self.type = type
        self.title = title
        self.body = body
        self.confidence = confidence
    }

    init(card: AIResultCard) {
        type = card.type
        title = card.title
        body = card.body
        confidence = card.confidence
    }
}

private struct WebPanelSummary: Encodable {
    let id: String
    let displayTimestamp: String
    let tagline: String
    let primaryIntent: String
    let intentConfidence: String
    let usedWebSearch: Bool

    init(record: SummaryRecord) {
        id = record.summaryURL.path
        displayTimestamp = record.displayTimestamp
        tagline = record.tagline
        primaryIntent = record.primaryIntent
        intentConfidence = record.intentConfidence
        usedWebSearch = record.usedWebSearch
    }
}

enum StatusIconFactory {
    static func mikuIcon() -> NSImage {
        if let image = assetImage(named: "miku_crop") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            return image
        }

        return fallbackMikuIcon()
    }

    private static func assetImage(named name: String) -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let fallbackURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(name).png")
        return NSImage(contentsOf: fallbackURL)
    }

    private static func fallbackMikuIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)

        NSColor.systemTeal.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.systemPink.setStroke()
        let twintail = NSBezierPath()
        twintail.move(to: NSPoint(x: 5, y: 8))
        twintail.curve(to: NSPoint(x: 1.5, y: 14), controlPoint1: NSPoint(x: 2, y: 8), controlPoint2: NSPoint(x: 2, y: 12))
        twintail.move(to: NSPoint(x: 13, y: 8))
        twintail.curve(to: NSPoint(x: 16.5, y: 14), controlPoint1: NSPoint(x: 16, y: 8), controlPoint2: NSPoint(x: 16, y: 12))
        twintail.lineWidth = 1.6
        twintail.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
