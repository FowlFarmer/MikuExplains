import AppKit

final class CollapseOverlayWindowController: NSWindowController {
    private let contentView = CollapsePanelView()
    private static let panelSize = NSSize(width: 460, height: 420)
    private static let panelMargin: CGFloat = 18

    init() {
        let window = CollapsePanelWindow(
            contentRect: Self.panelFrame(),
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

    func showSummary(title: String, summary: String, validity: String?, debug: String, onBack: @escaping () -> Void) {
        contentView.showSummary(title: title, summary: summary, validity: validity, debug: debug, onBack: onBack)
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

    func appendDebugLine(_ line: String) {
        contentView.appendDebugLine(line)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func showPanel() {
        guard let window else {
            return
        }

        let wasVisible = window.isVisible
        window.setFrame(Self.panelFrame(), display: false)
        window.setContentSize(Self.panelSize)

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

    private static func panelFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minX = visibleFrame.minX + panelMargin
        let maxX = visibleFrame.maxX - panelSize.width - panelMargin
        let minY = visibleFrame.minY + panelMargin
        let maxY = visibleFrame.maxY - panelSize.height - panelMargin
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

final class CollapsePanelView: NSView {
    private static let documentWidth: CGFloat = 380
    private static let historyHeight: CGFloat = 286
    private let cardView = NSView()
    private let rootStack = NSStackView()
    private let headerStack = NSStackView()
    private let backButton = NSButton(title: "← History", target: nil, action: nil)
    private let blackHoleView = BlackHoleView()
    private let titleLabel = NSTextField(labelWithString: "Denebula")
    private let statusLabel = NSTextField(labelWithString: "")
    private let debugSwitch = NSSwitch()
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let summaryTitleLabel = NSTextField(labelWithString: "Summary")
    private let loadingContainer = NSView()
    private let loadingRingView = LoadingRingView()
    private let loadingPercentLabel = NSTextField(labelWithString: "0%")
    private let loadingCaptionLabel = NSTextField(labelWithString: "Reading")
    private let summaryTextView = NSTextView()
    private let validityTitleLabel = NSTextField(labelWithString: "Validity")
    private let validityTextView = NSTextView()
    private let debugTitleLabel = NSTextField(labelWithString: "Debug")
    private let debugTextView = NSTextView()
    private let historyContentView = HistoryListView()
    private lazy var summaryScrollView = makeFlatTextScrollView(for: summaryTextView)
    private lazy var validityScrollView = makeValidityScrollView(for: validityTextView)
    private lazy var debugScrollView = makeScrollView(for: debugTextView)
    private lazy var historyScrollView = makeHistoryScrollView()
    private var onBack: (() -> Void)?
    private var onSelectHistoryItem: ((SummaryRecord) -> Void)?
    private var loadingTimer: Timer?
    private var loadingStartDate: Date?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configureCard()
        configureHeader()
        configureStacks()
        configureTextViews()
        buildLayout()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(title: String, debug: String, onBack: @escaping () -> Void) {
        self.onBack = onBack
        backButton.isHidden = false
        titleLabel.stringValue = title
        statusLabel.stringValue = ""
        setText(debug, in: debugTextView, scrollView: debugScrollView)
        showLoadingPage()
        startLoadingAnimation()
        blackHoleView.pulse()
    }

    func completeLoading(completion: @escaping @MainActor () -> Void) {
        loadingTimer?.invalidate()
        loadingTimer = nil
        let startProgress = loadingRingView.progress
        let startDate = Date()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                let elapsed = Date().timeIntervalSince(startDate)
                let fraction = min(1, elapsed / 0.28)
                let eased = 1 - pow(1 - fraction, 3)
                self.animateLoadingProgress(to: startProgress + (1 - startProgress) * eased)

                if fraction >= 1 {
                    self.loadingTimer?.invalidate()
                    self.loadingTimer = nil
                    completion()
                }
            }
        }
    }

    func showSummary(title: String, summary: String, validity: String?, debug: String, onBack: @escaping () -> Void) {
        stopLoadingAnimation()
        self.onBack = onBack
        backButton.isHidden = false
        titleLabel.stringValue = title.isEmpty ? "Summary" : title
        statusLabel.stringValue = ""
        summaryTitleLabel.stringValue = "Summary"
        setText(summary, in: summaryTextView, scrollView: summaryScrollView)
        setText(validity ?? "", in: validityTextView, scrollView: validityScrollView)
        setText(debug, in: debugTextView, scrollView: debugScrollView)
        showSummaryPage(hasValidity: validity?.isEmpty == false)
        blackHoleView.pulse()
    }

    func showHistory(_ summaries: [SummaryRecord], debug: String?, onSelect: @escaping (SummaryRecord) -> Void) {
        onBack = nil
        onSelectHistoryItem = onSelect
        backButton.isHidden = true
        titleLabel.stringValue = "Past Summaries"
        statusLabel.stringValue = "\(summaries.count) saved"
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.44)
        setText(debug ?? "History loaded from Application Support.", in: debugTextView, scrollView: debugScrollView)
        rebuildHistoryRows(summaries)
        stopLoadingAnimation()
        showHistoryPage()
        blackHoleView.pulse()
    }

    func showMessage(_ message: String) {
        onBack = nil
        backButton.isHidden = true
        titleLabel.stringValue = "Denebula"
        statusLabel.stringValue = "notice"
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.44)
        summaryTitleLabel.stringValue = "Message"
        setText(message, in: summaryTextView, scrollView: summaryScrollView)
        setText("", in: validityTextView, scrollView: validityScrollView)
        setText("", in: debugTextView, scrollView: debugScrollView)
        stopLoadingAnimation()
        showSummaryPage(hasValidity: false)
        blackHoleView.pulse()
    }

    func appendDebugLine(_ line: String) {
        let existingText = debugTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = existingText.isEmpty ? line : "\(existingText)\n\(line)"
        setText(newText, in: debugTextView, scrollView: debugScrollView)
        scrollToBottom(debugTextView)
    }

    private func configureCard() {
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor(calibratedWhite: 0.015, alpha: 1).cgColor
        cardView.layer?.cornerRadius = 20
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor(calibratedWhite: 0.28, alpha: 1).cgColor
        cardView.layer?.shadowColor = NSColor.black.cgColor
        cardView.layer?.shadowOpacity = 0.28
        cardView.layer?.shadowRadius = 30
        cardView.layer?.shadowOffset = NSSize(width: 0, height: -10)
    }

    private func configureHeader() {
        backButton.target = self
        backButton.action = #selector(backButtonPressed)
        backButton.bezelStyle = .inline
        backButton.font = .systemFont(ofSize: 12, weight: .medium)
        backButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        backButton.toolTip = "Show past summaries"
        backButton.setContentHuggingPriority(.required, for: .horizontal)

        blackHoleView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        debugSwitch.state = .off
        debugSwitch.target = self
        debugSwitch.action = #selector(debugSwitchChanged)
        debugSwitch.toolTip = "Toggle debug log"

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 17, weight: .semibold)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        closeButton.toolTip = "Close"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        [summaryTitleLabel, debugTitleLabel].forEach { label in
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor.white.withAlphaComponent(0.42)
        }

        validityTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        validityTitleLabel.textColor = NSColor.white.withAlphaComponent(0.42)

        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingRingView.translatesAutoresizingMaskIntoConstraints = false
        loadingPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingCaptionLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingPercentLabel.alignment = .center
        loadingPercentLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        loadingPercentLabel.textColor = .white

        loadingCaptionLabel.alignment = .center
        loadingCaptionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        loadingCaptionLabel.textColor = NSColor.white.withAlphaComponent(0.5)
    }

    private func configureStacks() {
        rootStack.orientation = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        historyContentView.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.documentWidth,
            height: Self.historyHeight
        )
        historyContentView.autoresizingMask = [.width]
    }

    private func configureTextViews() {
        [summaryTextView, validityTextView, debugTextView].forEach { textView in
            textView.frame = NSRect(x: 0, y: 0, width: Self.documentWidth, height: 120)
            textView.autoresizingMask = [.width]
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 13.5, weight: .regular)
            textView.textColor = NSColor.white.withAlphaComponent(0.9)
            textView.insertionPointColor = .white
            textView.textContainerInset = NSSize(width: 2, height: 2)
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: Self.documentWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.containerSize = NSSize(
                width: Self.documentWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.lineBreakMode = .byWordWrapping
        }

        debugTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        debugTextView.textColor = NSColor.white.withAlphaComponent(0.62)
        validityTextView.font = .systemFont(ofSize: 12.5, weight: .regular)
        validityTextView.textColor = NSColor.white.withAlphaComponent(0.78)
    }

    private func buildLayout() {
        addSubview(cardView)
        cardView.addSubview(rootStack)

        headerStack.addArrangedSubview(backButton)
        headerStack.addArrangedSubview(blackHoleView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(statusLabel)
        headerStack.addArrangedSubview(debugSwitch)
        headerStack.addArrangedSubview(closeButton)

        rootStack.addArrangedSubview(headerStack)
        loadingContainer.addSubview(loadingRingView)
        loadingContainer.addSubview(loadingPercentLabel)
        loadingContainer.addSubview(loadingCaptionLabel)
        rootStack.addArrangedSubview(loadingContainer)
        rootStack.addArrangedSubview(summaryTitleLabel)
        rootStack.addArrangedSubview(summaryScrollView)
        rootStack.addArrangedSubview(validityTitleLabel)
        rootStack.addArrangedSubview(validityScrollView)
        rootStack.addArrangedSubview(historyScrollView)
        rootStack.addArrangedSubview(debugTitleLabel)
        rootStack.addArrangedSubview(debugScrollView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            rootStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -20),

            blackHoleView.widthAnchor.constraint(equalToConstant: 34),
            blackHoleView.heightAnchor.constraint(equalToConstant: 34),
            backButton.widthAnchor.constraint(equalToConstant: 78),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            loadingContainer.heightAnchor.constraint(equalToConstant: 286),
            loadingRingView.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingRingView.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor, constant: -10),
            loadingRingView.widthAnchor.constraint(equalToConstant: 92),
            loadingRingView.heightAnchor.constraint(equalToConstant: 92),
            loadingPercentLabel.centerXAnchor.constraint(equalTo: loadingRingView.centerXAnchor),
            loadingPercentLabel.centerYAnchor.constraint(equalTo: loadingRingView.centerYAnchor),
            loadingCaptionLabel.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingCaptionLabel.topAnchor.constraint(equalTo: loadingRingView.bottomAnchor, constant: 18),
            loadingCaptionLabel.widthAnchor.constraint(equalTo: loadingContainer.widthAnchor),
            summaryScrollView.heightAnchor.constraint(equalToConstant: 248),
            validityScrollView.heightAnchor.constraint(equalToConstant: 86),
            historyScrollView.heightAnchor.constraint(equalToConstant: 286),
            debugScrollView.heightAnchor.constraint(equalToConstant: 76)
        ])

        setDebugVisible(false)
        showSummaryPage(hasValidity: false)
    }

    private func startLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingStartDate = Date()
        animateLoadingProgress(to: 0)

        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let loadingStartDate = self.loadingStartDate else {
                    return
                }

                let elapsed = Date().timeIntervalSince(loadingStartDate)
                let progress = min(0.96, 1 - exp(-elapsed / 3.2))
                self.animateLoadingProgress(to: progress)
            }
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingStartDate = nil
    }

    private func animateLoadingProgress(to progress: Double) {
        loadingRingView.progress = progress
        loadingPercentLabel.stringValue = "\(Int(round(progress * 100)))%"
    }

    private func showLoadingPage() {
        loadingContainer.isHidden = false
        summaryTitleLabel.isHidden = true
        summaryScrollView.isHidden = true
        validityTitleLabel.isHidden = true
        validityScrollView.isHidden = true
        historyScrollView.isHidden = true
        setDebugVisible(debugSwitch.state == .on)
    }

    private func showSummaryPage(hasValidity: Bool) {
        loadingContainer.isHidden = true
        summaryTitleLabel.isHidden = false
        summaryScrollView.isHidden = false
        validityTitleLabel.isHidden = !hasValidity
        validityScrollView.isHidden = !hasValidity
        historyScrollView.isHidden = true
        setDebugVisible(debugSwitch.state == .on)
    }

    private func showHistoryPage() {
        loadingContainer.isHidden = true
        summaryTitleLabel.isHidden = true
        summaryScrollView.isHidden = true
        validityTitleLabel.isHidden = true
        validityScrollView.isHidden = true
        historyScrollView.isHidden = false
        setDebugVisible(debugSwitch.state == .on)
    }

    private func setDebugVisible(_ isVisible: Bool) {
        debugTitleLabel.isHidden = !isVisible
        debugScrollView.isHidden = !isVisible
    }

    private func rebuildHistoryRows(_ summaries: [SummaryRecord]) {
        historyContentView.wantsLayer = true
        historyContentView.layer?.backgroundColor = NSColor.black.cgColor

        let contentWidth = Self.documentWidth
        let contentHeight = historyContentView.contentHeight(
            for: summaries.count,
            minimumHeight: Self.historyHeight
        )
        historyContentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        historyContentView.configure(summaries: summaries) { [weak self] summary in
            self?.onSelectHistoryItem?(summary)
        }

        historyContentView.needsDisplay = true
        historyScrollView.contentView.scroll(to: .zero)
        historyScrollView.reflectScrolledClipView(historyScrollView.contentView)
    }

    private func makeScrollView(for textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .clear
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 0
        scrollView.layer?.borderWidth = 0
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    private func makeFlatTextScrollView(for textView: NSTextView) -> NSScrollView {
        let scrollView = makeScrollView(for: textView)
        scrollView.backgroundColor = .clear
        scrollView.layer?.cornerRadius = 0
        scrollView.layer?.masksToBounds = false
        return scrollView
    }

    private func makeValidityScrollView(for textView: NSTextView) -> NSScrollView {
        makeFlatTextScrollView(for: textView)
    }

    private func makeHistoryScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .black
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.black.cgColor
        scrollView.layer?.cornerRadius = 0
        scrollView.layer?.borderWidth = 0
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .black
        scrollView.scrollerStyle = .overlay
        historyContentView.wantsLayer = true
        historyContentView.layer?.backgroundColor = NSColor.black.cgColor
        scrollView.documentView = historyContentView
        return scrollView
    }

    private func setText(_ text: String, in textView: NSTextView, scrollView: NSScrollView) {
        textView.string = text
        let textWidth = max(1, scrollView.contentSize.width - textView.textContainerInset.width * 2)
        textView.frame.size.width = textWidth
        textView.maxSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.needsDisplay = true
        scrollView.needsDisplay = true
    }

    private func scrollToBottom(_ textView: NSTextView) {
        let endRange = NSRange(location: textView.string.count, length: 0)
        textView.scrollRangeToVisible(endRange)
    }

    @objc private func backButtonPressed() {
        onBack?()
    }

    @objc private func debugSwitchChanged() {
        setDebugVisible(debugSwitch.state == .on)
    }

    @objc private func closeButtonPressed() {
        onClose?()
    }

}

private final class HistoryListView: NSView {
    private static let rowHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 2
    private var summaries: [SummaryRecord] = []
    private var onSelect: ((SummaryRecord) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    func configure(summaries: [SummaryRecord], onSelect: @escaping (SummaryRecord) -> Void) {
        self.summaries = summaries
        self.onSelect = onSelect
        needsDisplay = true
    }

    func contentHeight(for count: Int, minimumHeight: CGFloat) -> CGFloat {
        guard count > 0 else {
            return minimumHeight
        }

        return max(
            minimumHeight,
            CGFloat(count) * Self.rowHeight + CGFloat(max(count - 1, 0)) * Self.rowSpacing
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard !summaries.isEmpty else {
            drawEmptyMessage()
            return
        }

        summaries.enumerated().forEach { index, summary in
            draw(summary, at: index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rowStride = Self.rowHeight + Self.rowSpacing
        let index = Int(point.y / rowStride)
        let rowOffset = point.y - CGFloat(index) * rowStride

        guard summaries.indices.contains(index),
              rowOffset <= Self.rowHeight else {
            return
        }

        onSelect?(summaries[index])
    }

    private func drawEmptyMessage() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]
        "No summaries yet.".draw(
            in: NSRect(x: 0, y: 0, width: bounds.width, height: 24),
            withAttributes: attributes
        )
    }

    private func draw(_ summary: SummaryRecord, at index: Int) {
        let y = CGFloat(index) * (Self.rowHeight + Self.rowSpacing)
        let timestampAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ]
        let taglineAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        summary.displayTimestamp.draw(
            in: NSRect(x: 0, y: y + 11, width: 118, height: 18),
            withAttributes: timestampAttributes
        )
        summary.tagline.draw(
            in: NSRect(x: 132, y: y + 10, width: max(0, bounds.width - 132), height: 20),
            withAttributes: taglineAttributes
        )
    }
}

final class LoadingRingView: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 5, dy: 5)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let backgroundPath = NSBezierPath()
        backgroundPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360
        )
        NSColor.white.withAlphaComponent(0.12).setStroke()
        backgroundPath.lineWidth = 3
        backgroundPath.stroke()

        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(max(0, min(progress, 1)) * 360)
        let progressPath = NSBezierPath()
        progressPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        NSColor.white.withAlphaComponent(0.88).setStroke()
        progressPath.lineWidth = 3
        progressPath.lineCapStyle = .round
        progressPath.stroke()
    }
}

final class BlackHoleView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 4, dy: 4)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let ringPath = NSBezierPath(ovalIn: bounds)
        NSColor.white.withAlphaComponent(0.72).setStroke()
        ringPath.lineWidth = 2
        ringPath.stroke()

        NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 9, dy: 9)).fill()

        let accretionPath = NSBezierPath()
        accretionPath.move(to: NSPoint(x: bounds.minX + 3, y: bounds.midY - 2))
        accretionPath.curve(
            to: NSPoint(x: bounds.maxX - 2, y: bounds.midY + 3),
            controlPoint1: NSPoint(x: bounds.midX - 6, y: bounds.minY + 2),
            controlPoint2: NSPoint(x: bounds.midX + 7, y: bounds.maxY - 1)
        )
        NSColor.white.withAlphaComponent(0.38).setStroke()
        accretionPath.lineWidth = 1.5
        accretionPath.stroke()
    }

    func pulse() {
        alphaValue = 0.76
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }
}

enum StatusIconFactory {
    static func blackHoleIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)

        NSColor.labelColor.setStroke()
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 1.7
        ring.stroke()

        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 5.2, dy: 5.2)).fill()

        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3, y: 7))
        slash.curve(
            to: NSPoint(x: 15, y: 11),
            controlPoint1: NSPoint(x: 6, y: 2),
            controlPoint2: NSPoint(x: 12, y: 16)
        )
        slash.lineWidth = 1.4
        slash.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
