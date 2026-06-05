import ApplicationServices
import AppKit
import Foundation

enum SelectedTextReaderError: LocalizedError {
    case permissionRequired
    case noSelectedText

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Accessibility permission is required so Miku Explains can copy the current selection. Enable Miku Explains in System Settings > Privacy & Security > Accessibility."
        case .noSelectedText:
            "No selected text was copied from the frontmost app."
        }
    }
}

struct CapturedText {
    let text: String
    let source: CaptureSource
}

enum CaptureSource: String {
    case clipboard = "clipboard copy"
}

final class SelectedTextReader {
    func requestTrustIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func readSelectedText() -> Result<CapturedText, SelectedTextReaderError> {
        guard AXIsProcessTrusted() else {
            return .failure(.permissionRequired)
        }

        return readSelectedTextFromClipboard().map { text in
            CapturedText(text: text, source: .clipboard)
        }
    }

    private func readSelectedTextFromClipboard() -> Result<String, SelectedTextReaderError> {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map(PasteboardSnapshotItem.init(item:)) ?? []
        pasteboard.clearContents()
        let copyStartChangeCount = pasteboard.changeCount

        sendCopyShortcut()

        let deadline = Date().addingTimeInterval(1.0)
        while pasteboard.changeCount == copyStartChangeCount && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let copiedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        restorePasteboard(previousItems, to: pasteboard)

        guard let copiedText, copiedText.isEmpty == false else {
            return .failure(.noSelectedText)
        }

        return .success(copiedText)
    }

    private func sendCopyShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandFlag = CGEventFlags.maskCommand
        let cKeyCode = CGKeyCode(8)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        keyDown?.flags = commandFlag

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        keyUp?.flags = commandFlag

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func restorePasteboard(_ snapshot: [PasteboardSnapshotItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let items = snapshot.map { snapshotItem in
            let item = NSPasteboardItem()
            snapshotItem.dataByType.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }

        if items.isEmpty == false {
            pasteboard.writeObjects(items)
        }
    }
}

private struct PasteboardSnapshotItem {
    let dataByType: [NSPasteboard.PasteboardType: Data]

    init(item: NSPasteboardItem) {
        var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

        for type in item.types {
            if let data = item.data(forType: type) {
                dataByType[type] = data
            }
        }

        self.dataByType = dataByType
    }
}
