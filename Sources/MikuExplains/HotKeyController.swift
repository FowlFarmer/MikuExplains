@preconcurrency import Carbon
import Foundation

struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | shiftKey),
        keyName: "M"
    )

    var displayName: String {
        "\(modifierDisplay)\(keyName)"
    }

    private var modifierDisplay: String {
        var display = ""

        if modifiers & UInt32(controlKey) != 0 {
            display += "⌃"
        }

        if modifiers & UInt32(optionKey) != 0 {
            display += "⌥"
        }

        if modifiers & UInt32(shiftKey) != 0 {
            display += "⇧"
        }

        if modifiers & UInt32(cmdKey) != 0 {
            display += "⌘"
        }

        return display
    }

    static func fromWebKeyboardEvent(_ event: ShortcutKeyboardEvent) throws -> HotKeyShortcut {
        guard let key = keyMap[event.code] else {
            throw HotKeyShortcutError.unsupportedKey
        }

        var modifiers: UInt32 = 0
        if event.controlKey {
            modifiers |= UInt32(controlKey)
        }
        if event.altKey {
            modifiers |= UInt32(optionKey)
        }
        if event.shiftKey {
            modifiers |= UInt32(shiftKey)
        }
        if event.metaKey {
            modifiers |= UInt32(cmdKey)
        }

        let hasStrongModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasStrongModifier else {
            throw HotKeyShortcutError.missingModifier
        }

        return HotKeyShortcut(
            keyCode: key.keyCode,
            modifiers: modifiers,
            keyName: key.displayName
        )
    }

    private static let keyMap: [String: (keyCode: UInt32, displayName: String)] = [
        "Space": (UInt32(kVK_Space), "Space"),
        "Enter": (UInt32(kVK_Return), "Return"),
        "Tab": (UInt32(kVK_Tab), "Tab"),
        "Escape": (UInt32(kVK_Escape), "Esc"),
        "ArrowLeft": (UInt32(kVK_LeftArrow), "←"),
        "ArrowRight": (UInt32(kVK_RightArrow), "→"),
        "ArrowUp": (UInt32(kVK_UpArrow), "↑"),
        "ArrowDown": (UInt32(kVK_DownArrow), "↓"),
        "Minus": (UInt32(kVK_ANSI_Minus), "-"),
        "Equal": (UInt32(kVK_ANSI_Equal), "="),
        "BracketLeft": (UInt32(kVK_ANSI_LeftBracket), "["),
        "BracketRight": (UInt32(kVK_ANSI_RightBracket), "]"),
        "Backslash": (UInt32(kVK_ANSI_Backslash), "\\"),
        "Semicolon": (UInt32(kVK_ANSI_Semicolon), ";"),
        "Quote": (UInt32(kVK_ANSI_Quote), "'"),
        "Comma": (UInt32(kVK_ANSI_Comma), ","),
        "Period": (UInt32(kVK_ANSI_Period), "."),
        "Slash": (UInt32(kVK_ANSI_Slash), "/"),
        "Backquote": (UInt32(kVK_ANSI_Grave), "`"),
        "KeyA": (UInt32(kVK_ANSI_A), "A"),
        "KeyB": (UInt32(kVK_ANSI_B), "B"),
        "KeyC": (UInt32(kVK_ANSI_C), "C"),
        "KeyD": (UInt32(kVK_ANSI_D), "D"),
        "KeyE": (UInt32(kVK_ANSI_E), "E"),
        "KeyF": (UInt32(kVK_ANSI_F), "F"),
        "KeyG": (UInt32(kVK_ANSI_G), "G"),
        "KeyH": (UInt32(kVK_ANSI_H), "H"),
        "KeyI": (UInt32(kVK_ANSI_I), "I"),
        "KeyJ": (UInt32(kVK_ANSI_J), "J"),
        "KeyK": (UInt32(kVK_ANSI_K), "K"),
        "KeyL": (UInt32(kVK_ANSI_L), "L"),
        "KeyM": (UInt32(kVK_ANSI_M), "M"),
        "KeyN": (UInt32(kVK_ANSI_N), "N"),
        "KeyO": (UInt32(kVK_ANSI_O), "O"),
        "KeyP": (UInt32(kVK_ANSI_P), "P"),
        "KeyQ": (UInt32(kVK_ANSI_Q), "Q"),
        "KeyR": (UInt32(kVK_ANSI_R), "R"),
        "KeyS": (UInt32(kVK_ANSI_S), "S"),
        "KeyT": (UInt32(kVK_ANSI_T), "T"),
        "KeyU": (UInt32(kVK_ANSI_U), "U"),
        "KeyV": (UInt32(kVK_ANSI_V), "V"),
        "KeyW": (UInt32(kVK_ANSI_W), "W"),
        "KeyX": (UInt32(kVK_ANSI_X), "X"),
        "KeyY": (UInt32(kVK_ANSI_Y), "Y"),
        "KeyZ": (UInt32(kVK_ANSI_Z), "Z"),
        "Digit0": (UInt32(kVK_ANSI_0), "0"),
        "Digit1": (UInt32(kVK_ANSI_1), "1"),
        "Digit2": (UInt32(kVK_ANSI_2), "2"),
        "Digit3": (UInt32(kVK_ANSI_3), "3"),
        "Digit4": (UInt32(kVK_ANSI_4), "4"),
        "Digit5": (UInt32(kVK_ANSI_5), "5"),
        "Digit6": (UInt32(kVK_ANSI_6), "6"),
        "Digit7": (UInt32(kVK_ANSI_7), "7"),
        "Digit8": (UInt32(kVK_ANSI_8), "8"),
        "Digit9": (UInt32(kVK_ANSI_9), "9")
    ]
}

struct ShortcutKeyboardEvent {
    let code: String
    let controlKey: Bool
    let altKey: Bool
    let shiftKey: Bool
    let metaKey: Bool
}

enum HotKeyShortcutError: LocalizedError {
    case missingModifier
    case unsupportedKey
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingModifier:
            "Use Command, Option, or Control with your shortcut."
        case .unsupportedKey:
            "That key is not supported for the global shortcut."
        case .registrationFailed(let status):
            "macOS rejected that shortcut. It may already be in use. Status: \(status)."
        }
    }
}

final class HotKeyController: @unchecked Sendable {
    private let handler: @MainActor @Sendable () -> Void
    private var shortcut: HotKeyShortcut
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(shortcut: HotKeyShortcut, handler: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }

    @discardableResult
    func register() -> Result<Void, HotKeyShortcutError> {
        installEventHandlerIfNeeded()
        return registerHotKey(shortcut)
    }

    @discardableResult
    func updateShortcut(_ newShortcut: HotKeyShortcut) -> Result<Void, HotKeyShortcutError> {
        let previousShortcut = shortcut
        unregisterHotKey()
        shortcut = newShortcut

        let result = registerHotKey(newShortcut)
        if case .failure = result {
            shortcut = previousShortcut
            _ = registerHotKey(previousShortcut)
        }

        return result
    }

    func unregister() {
        unregisterHotKey()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr, hotKeyID.id == HotKeyController.hotKeyID else {
                    return noErr
                }

                let controller = Unmanaged<HotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.handler()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandlerRef
        )
    }

    private func registerHotKey(_ shortcut: HotKeyShortcut) -> Result<Void, HotKeyShortcutError> {
        unregisterHotKey()

        let hotKeyID = EventHotKeyID(
            signature: HotKeyController.hotKeySignature,
            id: HotKeyController.hotKeyID
        )

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            return .success(())
        }

        hotKeyRef = nil
        return .failure(.registrationFailed(status))
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private static let hotKeyID: UInt32 = 1
    private static let hotKeySignature: OSType = fourCharCode("DNBL")

    private static func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for scalar in string.unicodeScalars {
            result = (result << 8) + OSType(scalar.value)
        }
        return result
    }
}
