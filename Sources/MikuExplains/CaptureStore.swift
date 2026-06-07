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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func save(_ text: String, capturedAt date: Date = Date()) throws -> CaptureRecord {
        let directory = try capturesDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = Self.timestampFormatter().string(from: date)
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

        let summaryRecord = SummaryRecord(
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
        try upsertSummaryIndex(summaryRecord)
        return summaryRecord
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

        let scannedSummaries = files
            .filter { $0.lastPathComponent.hasSuffix("-result.json") || $0.lastPathComponent.hasSuffix("-summary.md") }
            .compactMap { summaryURL in
                try? summaryMetadata(from: summaryURL, filenames: filenames)
            }
        let indexedSummaries = indexedSummaryMetadata(in: directory, filenames: filenames)
        let indexedBySummaryFilename = Dictionary(
            uniqueKeysWithValues: indexedSummaries.map { ($0.summaryURL.lastPathComponent, $0) }
        )
        let mergedSummaries = scannedSummaries.map { scanned in
            indexedBySummaryFilename[scanned.summaryURL.lastPathComponent] ?? scanned
        }
        if mergedSummaries.isEmpty == false {
            try? rewriteSummaryIndex(mergedSummaries)
        }
        return mergedSummaries.sorted { $0.timestamp > $1.timestamp }
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

    private func indexURL() throws -> URL {
        try capturesDirectory().appendingPathComponent("summary-index.json", isDirectory: false)
    }

    private func indexedSummaryMetadata(in directory: URL, filenames: Set<String>) -> [SummaryRecord] {
        guard let indexURL = try? indexURL(),
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(SummaryIndex.self, from: data) else {
            return []
        }

        return index.records.compactMap { entry in
            guard filenames.contains(entry.captureFilename),
                  filenames.contains(entry.summaryFilename) else {
                return nil
            }

            return SummaryRecord(
                timestamp: entry.timestamp,
                displayTimestamp: entry.displayTimestamp,
                tagline: entry.tagline,
                primaryIntent: entry.primaryIntent,
                intentConfidence: entry.intentConfidence,
                usedWebSearch: entry.usedWebSearch,
                cards: [],
                captureURL: directory.appendingPathComponent(entry.captureFilename, isDirectory: false),
                summaryURL: directory.appendingPathComponent(entry.summaryFilename, isDirectory: false)
            )
        }
    }

    private func upsertSummaryIndex(_ record: SummaryRecord) throws {
        var records = loadSummaryIndexRecords()
        let entry = SummaryIndexRecord(record: record)
        records.removeAll { $0.summaryFilename == entry.summaryFilename }
        records.append(entry)
        try writeSummaryIndex(records)
    }

    private func rewriteSummaryIndex(_ summaries: [SummaryRecord]) throws {
        try writeSummaryIndex(summaries.map(SummaryIndexRecord.init(record:)))
    }

    private func loadSummaryIndexRecords() -> [SummaryIndexRecord] {
        guard let indexURL = try? indexURL(),
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(SummaryIndex.self, from: data) else {
            return []
        }

        return index.records
    }

    private func writeSummaryIndex(_ records: [SummaryIndexRecord]) throws {
        let indexURL = try indexURL()
        let index = SummaryIndex(version: 1, records: records.sorted { $0.timestamp > $1.timestamp })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
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
        guard let date = Self.timestampFormatter().date(from: baseTimestamp) else {
            return timestamp
        }

        return Self.displayFormatter().string(from: date)
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }

    private static func displayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }
}

private struct SummaryIndex: Codable {
    let version: Int
    let records: [SummaryIndexRecord]
}

private struct SummaryIndexRecord: Codable {
    let timestamp: String
    let displayTimestamp: String
    let tagline: String
    let primaryIntent: String
    let intentConfidence: String
    let usedWebSearch: Bool
    let captureFilename: String
    let summaryFilename: String

    init(record: SummaryRecord) {
        timestamp = record.timestamp
        displayTimestamp = record.displayTimestamp
        tagline = record.tagline
        primaryIntent = record.primaryIntent
        intentConfidence = record.intentConfidence
        usedWebSearch = record.usedWebSearch
        captureFilename = record.captureURL.lastPathComponent
        summaryFilename = record.summaryURL.lastPathComponent
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
