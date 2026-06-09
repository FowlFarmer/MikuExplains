import Foundation
import LocalAuthentication
import Security

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

    var hasConfiguredKey: Bool {
        apiKey() != nil
    }

    /// True when a Gemini key is available through the `GEMINI_API_KEY` or
    /// `GOOGLE_API_KEY` environment variables, without touching the Keychain.
    /// Useful for deferring the macOS Keychain access prompt until the user
    /// actually picks a hosted Gemma model.
    var hasEnvironmentKey: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0.isEmpty == false }
    }

    func apiKey() -> String? {
        if let keychainKey = loadFromKeychain(), keychainKey.isEmpty == false {
            return keychainKey
        }

        if let legacyKey = loadFromKeychain(service: legacyService, account: account),
           legacyKey.isEmpty == false {
            try? save(legacyKey)
            try? deleteKeychainItem(service: legacyService, account: account, missingIsOK: true)
            return legacyKey
        }

        let environment = ProcessInfo.processInfo.environment
        return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
    }

    func save(_ apiKey: String) throws {
        try cleanupLegacyEncryptedStorage()

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete()
            return
        }

        let data = Data(trimmed.utf8)
        let query = keychainQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = "Miku Explains Gemini API Key"
            addQuery[kSecAttrDescription as String] = "Gemini API key for Miku Explains"
            addQuery[kSecAttrComment as String] = "Stored as a normal generic password item. No biometric or user-presence access control is requested."
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.keychain(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw APIKeyStoreError.keychain(status: updateStatus)
        }

        guard loadFromKeychain() == trimmed else {
            throw APIKeyStoreError.keychainVerificationFailed
        }
    }

    private func delete() throws {
        try deleteKeychainItem(account: account, missingIsOK: true)
        try deleteKeychainItem(service: legacyService, account: account, missingIsOK: true)
        try cleanupLegacyEncryptedStorage()
    }

    private func loadFromKeychain() -> String? {
        loadFromKeychain(service: service, account: account)
    }

    private func loadFromKeychain(service: String, account: String) -> String? {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupLegacyEncryptedStorage() throws {
        if let encryptedFileURL = try? legacyEncryptedAPIKeyURL(),
           fileManager.fileExists(atPath: encryptedFileURL.path) {
            try fileManager.removeItem(at: encryptedFileURL)
        }

        try deleteKeychainItem(account: legacyEncryptionKeyAccount, missingIsOK: true)
        try deleteKeychainItem(service: legacyService, account: legacyEncryptionKeyAccount, missingIsOK: true)
    }

    private func legacyEncryptedAPIKeyURL() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw APIKeyStoreError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent("MikuExplains", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("gemini-api-key.enc", isDirectory: false)
    }

    private func deleteKeychainItem(account: String, missingIsOK: Bool) throws {
        try deleteKeychainItem(service: service, account: account, missingIsOK: missingIsOK)
    }

    private func deleteKeychainItem(service: String, account: String, missingIsOK: Bool) throws {
        let status = SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || (missingIsOK && status == errSecItemNotFound) else {
            throw APIKeyStoreError.keychain(status: status)
        }
    }

    private func keychainQuery(account: String) -> [String: Any] {
        keychainQuery(service: service, account: account)
    }

    private func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum APIKeyStoreError: LocalizedError {
    case applicationSupportUnavailable
    case keychainVerificationFailed
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate Application Support."
        case .keychainVerificationFailed:
            "Gemini API key was written but could not be read back from Keychain."
        case .keychain(let status):
            "Keychain failed with status \(status)."
        }
    }
}
