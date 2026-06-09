import Foundation
import LocalAuthentication
import Security

enum GeminiKeyAccessState: Sendable {
    case available
    case missing
    case needsPermission
    case failed(OSStatus)

    var debugLabel: String {
        switch self {
        case .available:
            "available"
        case .missing:
            "missing"
        case .needsPermission:
            "needsPermission"
        case .failed(let status):
            "failed(\(status))"
        }
    }
}

final class GeminiAPIKeyStore: @unchecked Sendable {
    static let shared = GeminiAPIKeyStore()

    private let fileManager: FileManager
    private let service = "com.mikuexplains.app"
    private let legacyService = "app.miku-explains.prototype"
    private let account = "GeminiAPIKey"
    private let legacyEncryptionKeyAccount = "GeminiAPIEncryptionKey"

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var hasEnvironmentKey: Bool {
        environmentKey() != nil
    }

    /// Silent Keychain check. Never shows UI.
    func accessState() -> GeminiKeyAccessState {
        if hasEnvironmentKey {
            return .available
        }

        switch silentRead(service: service, account: account) {
        case .success:
            return .available
        case .notFound:
            switch silentRead(service: legacyService, account: account) {
            case .success:
                return .available
            case .notFound:
                return .missing
            case .needsPermission:
                return .needsPermission
            case .failed(let status):
                return .failed(status)
            }
        case .needsPermission:
            return .needsPermission
        case .failed(let status):
            return .failed(status)
        }
    }

    func debugSummary() -> String {
        if hasEnvironmentKey {
            return "source=env"
        }

        let primary = silentRead(service: service, account: account)
        let legacy = silentRead(service: legacyService, account: account)
        return "source=keychain primary=\(primary.debugLabel) legacy=\(legacy.debugLabel)"
    }

    /// Reads the Gemini key. Set `allowUI` to true only after the heads-up is dismissed.
    func readKey(allowUI: Bool) -> String? {
        if let environmentKey = environmentKey() {
            return environmentKey
        }

        if let key = readKey(from: service, account: account, allowUI: allowUI), key.isEmpty == false {
            return key
        }

        if let legacyKey = readKey(from: legacyService, account: account, allowUI: allowUI),
           legacyKey.isEmpty == false {
            try? save(legacyKey)
            try? deleteItem(service: legacyService, account: account, missingOK: true)
            return legacyKey
        }

        return nil
    }

    func save(_ apiKey: String) throws {
        try cleanupLegacyEncryptedStorage()

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try deleteItem(service: service, account: account, missingOK: true)
        try deleteItem(service: legacyService, account: account, missingOK: true)

        if trimmed.isEmpty {
            return
        }

        let data = Data(trimmed.utf8)
        let access = try trustedApplicationAccess(label: "Miku Explains Gemini API Key")
        var addQuery = query(service: service, account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "Miku Explains Gemini API Key"
        addQuery[kSecAttrDescription as String] = "Gemini API key for Miku Explains"
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse
        addQuery[kSecAttrAccess as String] = access

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GeminiAPIKeyStoreError.keychain(addStatus)
        }

        guard case .success(let verified) = readResult(service: service, account: account, allowUI: false),
              verified == trimmed else {
            throw GeminiAPIKeyStoreError.verificationFailed
        }
    }

    private enum ReadResult: Equatable {
        case success(String)
        case notFound
        case needsPermission
        case failed(OSStatus)

        var debugLabel: String {
            switch self {
            case .success(let key):
                "success(len=\(key.count))"
            case .notFound:
                "notFound"
            case .needsPermission:
                "needsPermission"
            case .failed(let status):
                "failed(\(status))"
            }
        }
    }

    private func silentRead(service: String, account: String) -> ReadResult {
        readResult(service: service, account: account, allowUI: false)
    }

    private func readResult(service: String, account: String, allowUI: Bool) -> ReadResult {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        if allowUI == false {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                return .failed(status)
            }
            return .success(key.trimmingCharacters(in: .whitespacesAndNewlines))
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .needsPermission
        default:
            return .failed(status)
        }
    }

    private func readKey(from service: String, account: String, allowUI: Bool) -> String? {
        switch readResult(service: service, account: account, allowUI: allowUI) {
        case .success(let key):
            if allowUI, key.isEmpty == false {
                try? save(key)
            }
            return key
        case .notFound, .needsPermission, .failed:
            return nil
        }
    }

    private func deleteStoredKey() throws {
        try deleteItem(account: account, missingOK: true)
        try deleteItem(service: legacyService, account: account, missingOK: true)
        try cleanupLegacyEncryptedStorage()
    }

    private func environmentKey() -> String? {
        let environment = ProcessInfo.processInfo.environment
        return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
    }

    private func cleanupLegacyEncryptedStorage() throws {
        if let encryptedFileURL = try? legacyEncryptedAPIKeyURL(),
           fileManager.fileExists(atPath: encryptedFileURL.path) {
            try fileManager.removeItem(at: encryptedFileURL)
        }

        try deleteItem(account: legacyEncryptionKeyAccount, missingOK: true)
        try deleteItem(service: legacyService, account: legacyEncryptionKeyAccount, missingOK: true)
    }

    private func legacyEncryptedAPIKeyURL() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw GeminiAPIKeyStoreError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent("MikuExplains", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("gemini-api-key.enc", isDirectory: false)
    }

    private func deleteItem(account: String, missingOK: Bool) throws {
        try deleteItem(service: service, account: account, missingOK: missingOK)
    }

    private func deleteItem(service: String, account: String, missingOK: Bool) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || (missingOK && status == errSecItemNotFound) else {
            throw GeminiAPIKeyStoreError.keychain(status)
        }
    }

    private func query(account: String) -> [String: Any] {
        query(service: service, account: account)
    }

    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func trustedApplicationAccess(label: String) throws -> SecAccess {
        var trustedApp: SecTrustedApplication?
        let executablePath = Bundle.main.executablePath
        let trustStatus = SecTrustedApplicationCreateFromPath(executablePath, &trustedApp)
        guard trustStatus == errSecSuccess, let trustedApp else {
            throw GeminiAPIKeyStoreError.keychain(trustStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, [trustedApp] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw GeminiAPIKeyStoreError.keychain(accessStatus)
        }

        return access
    }
}

enum GeminiAPIKeyStoreError: LocalizedError {
    case applicationSupportUnavailable
    case verificationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate Application Support."
        case .verificationFailed:
            "Gemini API key was written but could not be read back from Keychain."
        case .keychain(let status):
            "Keychain failed with status \(status)."
        }
    }
}
