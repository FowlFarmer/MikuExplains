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
            return "Could not find the Codex CLI. Install or open Codex so Miku Explains can use its login."
        case .launchFailed(let message):
            return "Could not launch Codex: \(message)"
        case .failed(let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.isEmpty ? "(no output)" : String(trimmed.prefix(200))
            if status == 0 {
                return "AI backend error: \(snippet)"
            }
            return "AI backend failed with status \(status): \(snippet)"
        case .unreadableOutput(let message):
            return "Could not read Codex output: \(message)"
        case .invalidOutput(let output):
            return "The AI backend returned an invalid result format: \(output)"
        case .saveFailed(let message):
            return "Could not save AI result: \(message)"
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
        onWebSearchStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        guard let codexURL = codexExecutableURL() else {
            complete(.failure(.codexExecutableNotFound), completion: completion)
            return
        }

        runCodex(
            codexURL: codexURL,
            record: record,
            prompt: InferencePromptBuilder.localPrompt(for: record, backend: .codex),
            usesWebSearch: false,
            onProcessStarted: onProcessStarted
        ) { [self, captureStore] result in
            switch result {
            case .failure(let error):
                complete(.failure(error), completion: completion)
            case .success(let localResult):
                guard localResult.needsWebSearch else {
                    save(localResult, record: record, captureStore: captureStore, completion: completion)
                    return
                }

                Task { @MainActor in
                    onWebSearchStarted()
                }

                runCodex(
                    codexURL: codexURL,
                    record: record,
                    prompt: InferencePromptBuilder.webPrompt(for: record, localResult: localResult),
                    usesWebSearch: true,
                    onProcessStarted: onProcessStarted
                ) { [self, captureStore] webResult in
                    switch webResult {
                    case .success(let finalResult):
                        save(finalResult, record: record, captureStore: captureStore, completion: completion)
                    case .failure(let error):
                        complete(.failure(error), completion: completion)
                    }
                }
            }
        }
    }

    private func runCodex(
        codexURL: URL,
        record: CaptureRecord,
        prompt: String,
        usesWebSearch: Bool,
        onProcessStarted: @escaping @MainActor @Sendable (Int32) -> Void,
        completion: @escaping @Sendable (Result<ParsedCodexSummary, CodexSummarizerError>) -> Void
    ) {
        let process = Process()
        process.executableURL = codexURL
        process.currentDirectoryURL = record.captureURL.deletingLastPathComponent()

        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            record.rawSummaryURL.path,
            prompt
        ]

        if usesWebSearch {
            arguments.insert("--search", at: 0)
        }

        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { process in
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                completion(.failure(.failed(status: process.terminationStatus, output: output)))
                return
            }

            do {
                var rawOutput = try String(contentsOf: record.rawSummaryURL, encoding: .utf8)

                // Codex sometimes exits 0 but writes an ERROR line when auth
                // or network fails. Detect it before attempting JSON parse.
                let firstLine = rawOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .first ?? ""
                if firstLine.uppercased().hasPrefix("ERROR") {
                    let message = firstLine
                        .replacingOccurrences(of: "^error[: ]*", with: "", options: [.regularExpression, .caseInsensitive])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let friendly = message.isEmpty ? "Codex returned an error." : message
                    completion(.failure(.failed(status: 0, output: friendly)))
                    return
                }

                // Strip any accidental "ERROR …" lines interspersed before the JSON.
                let cleaned = rawOutput
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ERROR") }
                    .joined(separator: "\n")
                rawOutput = cleaned

                let parsedResult = try ParsedCodexSummary.parse(rawOutput)
                completion(.success(parsedResult))
            } catch let error as CodexSummarizerError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unreadableOutput(error.localizedDescription)))
            }
        }

        do {
            try process.run()
            Task { @MainActor in
                onProcessStarted(process.processIdentifier)
            }
            // Hard timeout: kill Codex if it hasn't finished in 90 seconds.
            // This guards against stdin-read hangs or network stalls.
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 90) {
                guard process.isRunning else { return }
                NSLog("CodexSummarizer: hard timeout — killing PID %d", process.processIdentifier)
                process.terminate()
            }
        } catch {
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    private func save(
        _ result: ParsedCodexSummary,
        record: CaptureRecord,
        captureStore: CaptureStore,
        completion: @escaping @MainActor @Sendable (Result<SummaryRecord, CodexSummarizerError>) -> Void
    ) {
        do {
            let savedResult = try captureStore.saveSummary(result, for: record)
            complete(.success(savedResult), completion: completion)
        } catch {
            complete(.failure(.saveFailed(error.localizedDescription)), completion: completion)
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
