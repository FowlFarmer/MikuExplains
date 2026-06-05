import Foundation

enum CaptureStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidResultFilename(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Could not locate Application Support."
        case .invalidResultFilename(let filename):
            "Invalid result filename: \(filename)"
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
        let resultURL = record.captureURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(record.captureBaseName)-\(taglineSlug)-result.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let resultData = try encoder.encode(parsedSummary)
        try resultData.write(to: resultURL, options: .atomic)
        try? fileManager.removeItem(at: record.rawSummaryURL)

        return SummaryRecord(
            timestamp: record.captureBaseName,
            displayTimestamp: displayTimestamp(for: record.captureBaseName),
            tagline: parsedSummary.tagline,
            primaryIntent: parsedSummary.primaryIntent,
            intentConfidence: parsedSummary.intentConfidence,
            usedWebSearch: parsedSummary.usedWebSearch,
            cards: parsedSummary.cards,
            captureURL: record.captureURL,
            summaryURL: resultURL
        )
    }

    func listSummaries() throws -> [SummaryRecord] {
        let directory = try capturesDirectory()
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let filenames = Set(files.map(\.lastPathComponent))

        return files
            .filter { $0.lastPathComponent.hasSuffix("-result.json") || $0.lastPathComponent.hasSuffix("-summary.md") }
            .compactMap { summaryURL in
                try? summaryMetadata(from: summaryURL, filenames: filenames)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func loadSummary(_ record: SummaryRecord) throws -> SummaryRecord {
        if record.summaryURL.lastPathComponent.hasSuffix("-result.json") {
            let data = try Data(contentsOf: record.summaryURL)
            let parsedResult = try JSONDecoder().decode(ParsedCodexSummary.self, from: data)
            return SummaryRecord(
                timestamp: record.timestamp,
                displayTimestamp: record.displayTimestamp,
                tagline: parsedResult.tagline,
                primaryIntent: parsedResult.primaryIntent,
                intentConfidence: parsedResult.intentConfidence,
                usedWebSearch: parsedResult.usedWebSearch,
                cards: parsedResult.cards,
                captureURL: record.captureURL,
                summaryURL: record.summaryURL
            )
        }

        let summaryMarkdown = try String(contentsOf: record.summaryURL, encoding: .utf8)
        let cards = cardsFromLegacySummaryMarkdown(summaryMarkdown)
        return SummaryRecord(
            timestamp: record.timestamp,
            displayTimestamp: record.displayTimestamp,
            tagline: record.tagline,
            primaryIntent: "summary",
            intentConfidence: "legacy",
            usedWebSearch: false,
            cards: cards,
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
            .appendingPathComponent("MikuExplains", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    private func summaryMetadata(from summaryURL: URL, filenames: Set<String>) throws -> SummaryRecord {
        let filename = summaryURL.lastPathComponent
        guard filename.hasSuffix("-result.json") || filename.hasSuffix("-summary.md") else {
            throw CaptureStoreError.invalidResultFilename(filename)
        }

        let isJSONResult = filename.hasSuffix("-result.json")
        let suffix = isJSONResult ? "-result.json" : "-summary.md"
        let stem = String(filename.dropLast(suffix.count))
        let timestampPattern = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:-\d+)?"#
        guard let timestampRange = stem.range(of: timestampPattern, options: .regularExpression) else {
            throw CaptureStoreError.invalidResultFilename(filename)
        }

        let timestamp = String(stem[timestampRange])
        let slugStart = timestampRange.upperBound
        let taglineSlug = stem[slugStart...].dropFirst()
        let captureURL = summaryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(timestamp).md")

        guard filenames.contains("\(timestamp).md") else {
            throw CaptureStoreError.invalidResultFilename(filename)
        }

        return SummaryRecord(
            timestamp: timestamp,
            displayTimestamp: displayTimestamp(for: timestamp),
            tagline: displayTagline(from: String(taglineSlug)),
            primaryIntent: isJSONResult ? "result" : "summary",
            intentConfidence: isJSONResult ? "unknown" : "legacy",
            usedWebSearch: false,
            cards: [],
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

    private func cardsFromLegacySummaryMarkdown(_ markdown: String) -> [AIResultCard] {
        let splitSummary = splitValidity(from: markdown)
        var cards = [
            AIResultCard(
                type: "summary",
                title: "Summary",
                body: splitSummary.summary,
                confidence: nil
            )
        ]

        if let validityAnalysis = splitSummary.validityAnalysis {
            cards.append(
                AIResultCard(
                    type: "validity",
                    title: "Validity",
                    body: validityAnalysis,
                    confidence: nil
                )
            )
        }

        return cards
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
    let primaryIntent: String
    let intentConfidence: String
    let usedWebSearch: Bool
    let cards: [AIResultCard]
    let captureURL: URL
    let summaryURL: URL
}
