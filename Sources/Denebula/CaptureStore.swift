import Foundation

enum CaptureStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidSummaryFilename(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate Application Support."
        case .invalidSummaryFilename(let filename):
            "Invalid summary filename: \(filename)"
        }
    }
}

final class CaptureStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let timestampFormatter: DateFormatter
    private let displayFormatter: DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        self.timestampFormatter = timestampFormatter

        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale.current
        displayFormatter.dateFormat = "MMM d, h:mm a"
        self.displayFormatter = displayFormatter
    }

    func save(_ text: String, capturedAt date: Date = Date()) throws -> CaptureRecord {
        let directory = try capturesDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = timestampFormatter.string(from: date)
        var fileURL = directory.appendingPathComponent("\(baseName).md")
        var duplicateIndex = 2

        while fileManager.fileExists(atPath: fileURL.path) {
            fileURL = directory.appendingPathComponent("\(baseName)-\(duplicateIndex).md")
            duplicateIndex += 1
        }

        try text.write(to: fileURL, atomically: true, encoding: .utf8)

        let captureBaseName = fileURL.deletingPathExtension().lastPathComponent
        return CaptureRecord(
            captureURL: fileURL,
            rawSummaryURL: directory.appendingPathComponent("\(captureBaseName)-codex-output.tmp"),
            captureBaseName: captureBaseName
        )
    }

    func saveSummary(_ parsedSummary: ParsedCodexSummary, for record: CaptureRecord) throws -> SummaryRecord {
        let taglineSlug = slug(for: parsedSummary.tagline)
        let summaryURL = record.captureURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(record.captureBaseName)-\(taglineSlug)-summary.md")

        let summaryMarkdown = summaryMarkdown(for: parsedSummary)
        try summaryMarkdown.write(to: summaryURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: record.rawSummaryURL)

        return SummaryRecord(
            timestamp: record.captureBaseName,
            displayTimestamp: displayTimestamp(for: record.captureBaseName),
            tagline: parsedSummary.tagline,
            summary: parsedSummary.summary,
            validityAnalysis: parsedSummary.validityAnalysis,
            captureURL: record.captureURL,
            summaryURL: summaryURL
        )
    }

    func listSummaries() throws -> [SummaryRecord] {
        let directory = try capturesDirectory()
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return files
            .filter { $0.lastPathComponent.hasSuffix("-summary.md") }
            .compactMap { summaryURL in
                try? summaryMetadata(from: summaryURL)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func loadSummary(_ record: SummaryRecord) throws -> SummaryRecord {
        let summaryMarkdown = try String(contentsOf: record.summaryURL, encoding: .utf8)
        let splitSummary = splitValidity(from: summaryMarkdown)
        return SummaryRecord(
            timestamp: record.timestamp,
            displayTimestamp: record.displayTimestamp,
            tagline: record.tagline,
            summary: splitSummary.summary,
            validityAnalysis: splitSummary.validityAnalysis,
            captureURL: record.captureURL,
            summaryURL: record.summaryURL
        )
    }

    func capturesDirectory() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CaptureStoreError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent("Denebula", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    private func summaryMetadata(from summaryURL: URL) throws -> SummaryRecord {
        let filename = summaryURL.lastPathComponent
        guard filename.hasSuffix("-summary.md") else {
            throw CaptureStoreError.invalidSummaryFilename(filename)
        }

        let stem = String(filename.dropLast("-summary.md".count))
        let timestampPattern = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:-\d+)?"#
        guard let timestampRange = stem.range(of: timestampPattern, options: .regularExpression) else {
            throw CaptureStoreError.invalidSummaryFilename(filename)
        }

        let timestamp = String(stem[timestampRange])
        let slugStart = timestampRange.upperBound
        let taglineSlug = stem[slugStart...].dropFirst()
        let captureURL = summaryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(timestamp).md")

        guard fileManager.fileExists(atPath: captureURL.path) else {
            throw CaptureStoreError.invalidSummaryFilename(filename)
        }

        return SummaryRecord(
            timestamp: timestamp,
            displayTimestamp: displayTimestamp(for: timestamp),
            tagline: displayTagline(from: String(taglineSlug)),
            summary: "",
            validityAnalysis: nil,
            captureURL: captureURL,
            summaryURL: summaryURL
        )
    }

    private func slug(for tagline: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        let cleaned = tagline
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .lowercased()

        let words = cleaned
            .split(separator: " ")
            .prefix(5)
            .map(String.init)

        return words.isEmpty ? "summary" : words.joined(separator: "-")
    }

    private func summaryMarkdown(for parsedSummary: ParsedCodexSummary) -> String {
        guard let validityAnalysis = parsedSummary.validityAnalysis,
              validityAnalysis.isEmpty == false else {
            return parsedSummary.summary
        }

        return """
        \(parsedSummary.summary)

        ## Validity

        \(validityAnalysis)
        """
    }

    private func displayTagline(from slug: String) -> String {
        slug
            .split(separator: "-")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private func splitValidity(from markdown: String) -> (summary: String, validityAnalysis: String?) {
        let marker = "\n## Validity\n"
        guard let range = markdown.range(of: marker) else {
            return (markdown.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let summary = markdown[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let validity = markdown[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(summary), validity.isEmpty ? nil : String(validity))
    }

    private func displayTimestamp(for timestamp: String) -> String {
        let baseTimestamp = String(timestamp.prefix(19))
        guard let date = timestampFormatter.date(from: baseTimestamp) else {
            return timestamp
        }

        return displayFormatter.string(from: date)
    }
}

struct CaptureRecord {
    let captureURL: URL
    let rawSummaryURL: URL
    let captureBaseName: String
}

struct SummaryRecord {
    let timestamp: String
    let displayTimestamp: String
    let tagline: String
    let summary: String
    let validityAnalysis: String?
    let captureURL: URL
    let summaryURL: URL
}
