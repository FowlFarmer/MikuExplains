import Foundation

enum CodexSummarizerError: LocalizedError {
    case codexExecutableNotFound
    case launchFailed(String)
    case failed(status: Int32, output: String)
    case unreadableOutput(String)
    case invalidOutput(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            "Could not find the Codex CLI. Install or open Codex so Denebula can use its login."
        case .launchFailed(let message):
            "Could not launch Codex: \(message)"
        case .failed(let status, let output):
            "Codex summarization failed with status \(status): \(output)"
        case .unreadableOutput(let message):
            "Could not read Codex output: \(message)"
        case .invalidOutput(let output):
            "Codex returned an invalid summary format: \(output)"
        case .saveFailed(let message):
            "Could not save Codex summary: \(message)"
        }
    }
}

final class CodexSummarizer: @unchecked Sendable {
    private let fileManager: FileManager
    private let captureStore: CaptureStore

    init(fileManager: FileManager = .default, captureStore: CaptureStore) {
        self.fileManager = fileManager
        self.captureStore = captureStore
    }

    func summarize(
        record: CaptureRecord,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        guard let codexURL = codexExecutableURL() else {
            complete(.failure(.codexExecutableNotFound), completion: completion)
            return
        }

        let process = Process()
        process.executableURL = codexURL
        process.currentDirectoryURL = record.captureURL.deletingLastPathComponent()
        process.arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            record.rawSummaryURL.path,
            """
            Summarize the Markdown file at this path:
            \(record.captureURL.path)

            Return exactly this plain-text format using regular ASCII characters:
            TAGLINE: fewer than five words
            VALIDITY_APPLICABLE: yes or no
            VALIDITY:
            If VALIDITY_APPLICABLE is yes, write a short analysis of whether the factual claims appear truthful, false, misleading, or uncertain. Mention uncertainty when the claim would require current or external verification. If VALIDITY_APPLICABLE is no, write NOT_APPLICABLE.
            SUMMARY:
            A complete Markdown summary of all important points.

            The TAGLINE must be 1 to 4 words, contain only letters, numbers, and spaces, and must not include punctuation.
            The SUMMARY should preserve all important points while being concise and useful.
            Only set VALIDITY_APPLICABLE to yes when the captured text is making factual, verifiable claims. If the text is fiction, personal preference, instructions, UI copy, brainstorming, code, or otherwise not asserting factual information, set VALIDITY_APPLICABLE to no.
            """
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [self, captureStore] process in
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                self.complete(
                    .failure(.failed(status: process.terminationStatus, output: output)),
                    completion: completion
                )
                return
            }

            do {
                let rawOutput = try String(contentsOf: record.rawSummaryURL, encoding: .utf8)
                let parsedSummary = try ParsedCodexSummary.parse(rawOutput)
                let savedSummary = try captureStore.saveSummary(parsedSummary, for: record)
                self.complete(.success(savedSummary), completion: completion)
            } catch let error as CodexSummarizerError {
                self.complete(.failure(error), completion: completion)
            } catch {
                self.complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
            }
        }

        do {
            try process.run()
            Task { @MainActor in
                onProcessStarted(process.processIdentifier)
            }
        } catch {
            complete(.failure(.launchFailed(error.localizedDescription)), completion: completion)
        }
    }

    private func complete(
        _ result: Result<SummaryRecord, CodexSummarizerError>,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        Task { @MainActor in
            completion(result)
        }
    }

    private func codexExecutableURL() -> URL? {
        let bundledCodex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if fileManager.isExecutableFile(atPath: bundledCodex.path) {
            return bundledCodex
        }

        let usrLocalCodex = URL(fileURLWithPath: "/usr/local/bin/codex")
        if fileManager.isExecutableFile(atPath: usrLocalCodex.path) {
            return usrLocalCodex
        }

        let optHomebrewCodex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        if fileManager.isExecutableFile(atPath: optHomebrewCodex.path) {
            return optHomebrewCodex
        }

        return nil
    }
}

struct ParsedCodexSummary {
    let tagline: String
    let summary: String
    let validityAnalysis: String?

    static func parse(_ output: String) throws -> ParsedCodexSummary {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmedOutput.components(separatedBy: .newlines)

        guard let firstLine = lines.first,
              firstLine.uppercased().hasPrefix("TAGLINE:") else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        let rawTagline = String(firstLine.dropFirst("TAGLINE:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tagline = sanitizeTagline(rawTagline)

        guard let validityApplicableLine = lines.first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("VALIDITY_APPLICABLE:")
        }) else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        let validityApplicableValue = String(validityApplicableLine.dropFirst("VALIDITY_APPLICABLE:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let shouldShowValidity = validityApplicableValue == "yes"

        guard let validityMarkerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "VALIDITY:"
        }) else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        guard let summaryMarkerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "SUMMARY:"
        }) else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        guard validityMarkerIndex < summaryMarkerIndex else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        let rawValidity = lines
            .dropFirst(validityMarkerIndex + 1)
            .prefix(summaryMarkerIndex - validityMarkerIndex - 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let summary = lines
            .dropFirst(summaryMarkerIndex + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard tagline.isEmpty == false, summary.isEmpty == false else {
            throw CodexSummarizerError.invalidOutput(trimmedOutput)
        }

        let validityAnalysis = shouldShowValidity && rawValidity.uppercased() != "NOT_APPLICABLE"
            ? rawValidity
            : nil

        return ParsedCodexSummary(
            tagline: tagline,
            summary: summary,
            validityAnalysis: validityAnalysis
        )
    }

    private static func sanitizeTagline(_ tagline: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet.whitespaces)
        let cleaned = tagline.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : " "
        }.reduce(into: "") { result, character in
            result.append(character)
        }

        return cleaned
            .split(separator: " ")
            .prefix(4)
            .joined(separator: " ")
    }
}
