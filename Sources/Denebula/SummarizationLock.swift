import Foundation

enum SummarizationLockError: LocalizedError {
    case applicationSupportUnavailable
    case alreadyRunning(SummarizationLockRecord)
    case createFailed

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate Application Support."
        case .alreadyRunning(let record):
            "A summary is already running from \(record.displayStartedAt)."
        case .createFailed:
            "Could not create the summarization lock."
        }
    }
}

struct SummarizationLockToken {
    let id: String
}

struct SummarizationLockRecord: Codable {
    let id: String
    let processIdentifier: Int32
    let startedAt: Date

    var displayStartedAt: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: startedAt)
    }
}

final class SummarizationLock: @unchecked Sendable {
    private let fileManager: FileManager
    private let staleInterval: TimeInterval

    init(fileManager: FileManager = .default, staleInterval: TimeInterval = 6 * 60 * 60) {
        self.fileManager = fileManager
        self.staleInterval = staleInterval
    }

    func acquire() throws -> SummarizationLockToken {
        let lockURL = try lockFileURL()
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let existingRecord = readRecord(from: lockURL) {
            if isStale(existingRecord) {
                try? fileManager.removeItem(at: lockURL)
            } else {
                throw SummarizationLockError.alreadyRunning(existingRecord)
            }
        }

        let record = SummarizationLockRecord(
            id: UUID().uuidString,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date()
        )
        let data = try JSONEncoder().encode(record)

        guard fileManager.createFile(atPath: lockURL.path, contents: data) else {
            if let existingRecord = readRecord(from: lockURL),
               isStale(existingRecord) == false {
                throw SummarizationLockError.alreadyRunning(existingRecord)
            }

            throw SummarizationLockError.createFailed
        }

        return SummarizationLockToken(id: record.id)
    }

    func release(_ token: SummarizationLockToken) {
        guard let lockURL = try? lockFileURL(),
              let record = readRecord(from: lockURL),
              record.id == token.id else {
            return
        }

        try? fileManager.removeItem(at: lockURL)
    }

    func updateProcessIdentifier(_ processIdentifier: Int32, for token: SummarizationLockToken) {
        guard let lockURL = try? lockFileURL(),
              let record = readRecord(from: lockURL),
              record.id == token.id else {
            return
        }

        let updatedRecord = SummarizationLockRecord(
            id: record.id,
            processIdentifier: processIdentifier,
            startedAt: record.startedAt
        )

        guard let data = try? JSONEncoder().encode(updatedRecord) else {
            return
        }

        try? data.write(to: lockURL, options: .atomic)
    }

    private func lockFileURL() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SummarizationLockError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent("Denebula", isDirectory: true)
            .appendingPathComponent("summarization.lock")
    }

    private func readRecord(from url: URL) -> SummarizationLockRecord? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(SummarizationLockRecord.self, from: data)
    }

    private func isStale(_ record: SummarizationLockRecord) -> Bool {
        if Date().timeIntervalSince(record.startedAt) > staleInterval {
            return true
        }

        return isProcessRunning(record.processIdentifier) == false
    }

    private func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else {
            return false
        }

        return kill(processIdentifier, 0) == 0 || errno == EPERM
    }
}
