import Foundation

// Simple heap box to safely pass a value across concurrency boundaries
// in semaphore-guarded synchronous code.
final class UnsafeMutableTransfer<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Manages the local Ollama server lifecycle and model operations.
///
/// - Checks if an Ollama server is already running (another app may have
///   started it). If not, spawns `ollama serve` as a child process.
/// - Lists installed models via `GET /api/tags`.
/// - Pulls models via `POST /api/pull` with streaming NDJSON progress.
final class OllamaManager: @unchecked Sendable {
    static let shared = OllamaManager()

    private(set) var baseURL: URL
    private var serverProcess: Process?

    private init() {
        let base = ProcessInfo.processInfo.environment["MIKU_OLLAMA_BASE"]
            ?? "http://localhost:11434"
        self.baseURL = URL(string: base) ?? URL(string: "http://localhost:11434")!
    }

    // MARK: - Server lifecycle

    /// True when the Ollama binary exists somewhere on the machine.
    var isOllamaInstalled: Bool {
        ollamaBinary() != nil
    }

    /// Synchronous check — pings /api/tags with a 1.5s timeout.
    func isServerRunning() -> Bool {
        let url = baseURL.appendingPathComponent("/api/tags")
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        let box = UnsafeMutableTransfer(false)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                box.value = true
            }
            sem.signal()
        }.resume()
        sem.wait()
        return box.value
    }

    /// Ensures the server is up. Spawns `ollama serve` if needed, then polls
    /// until the server responds (up to 15 s) instead of sleeping a fixed interval.
    @discardableResult
    func ensureServerRunning() -> Bool {
        if isServerRunning() {
            NSLog("OllamaManager: server already running")
            return true
        }
        guard let binary = ollamaBinary() else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            NSLog("OllamaManager: ollama binary not found. HOME=%@, checked /usr/local/bin/ollama, /opt/homebrew/bin/ollama, %@/.ollama/bin/ollama", home, home)
            return false
        }
        NSLog("OllamaManager: launching %@", binary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            serverProcess = process
            NSLog("OllamaManager: launched ollama serve (PID %d)", process.processIdentifier)
        } catch {
            NSLog("OllamaManager: failed to launch: %@", error.localizedDescription)
            return false
        }
        // Poll until server responds, up to 15 s
        let deadline = Date().addingTimeInterval(15)
        var attempts = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            attempts += 1
            if isServerRunning() {
                NSLog("OllamaManager: server up after %d polls", attempts)
                return true
            }
            // Check if process already exited
            if !process.isRunning {
                NSLog("OllamaManager: ollama serve exited early (status %d)", process.terminationStatus)
                return false
            }
        }
        NSLog("OllamaManager: server did not respond within 15 s after %d polls", attempts)
        return false
    }

    /// Terminate our managed server process (if any). Externally started
    /// Ollama servers are left running.
    func stopManagedServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: - Model listing

    /// Returns the list of installed model name tags.
    func listInstalledModels(completion: @escaping @MainActor ([String]) -> Void) {
        let url = baseURL.appendingPathComponent("/api/tags")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var tags: [String] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                tags = models.compactMap { $0["name"] as? String }
            }
            Task { @MainActor in completion(tags) }
        }.resume()
    }

    // MARK: - Model pulling

    /// Downloads a model from the Ollama registry, streaming progress (0–1).
    /// On completion calls completion(.success) or completion(.failure).
    func pullModel(
        _ tag: String,
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        let url = baseURL.appendingPathComponent("/api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 7200 // large models can take a while
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["model": tag, "stream": true]
        )
        let delegate = PullStreamDelegate(tag: tag, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: request).resume()
    }

    // MARK: - Ollama self-install

    /// Downloads the ollama CLI from ollama.com if it isn't already installed.
    /// Saves to ~/.ollama/bin/ollama and marks it executable.
    func ensureOllamaInstalled(
        progress: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        if isOllamaInstalled {
            Task { @MainActor in completion(.success(())) }
            return
        }

        Task { @MainActor in progress("Downloading Ollama…") }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let destDir = "\(home)/.ollama/bin"
        let destPath = "\(destDir)/ollama"

        // Use curl (handles GitHub redirects correctly) to download and pipe
        // straight into tar. No sudo — installs to ~/.ollama/bin/ollama only.
        let script = """
            set -e
            mkdir -p "\(destDir)"
            curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz" \
                | tar -xz -C "\(destDir)"
            # tgz may extract as bin/ollama inside destDir; flatten if needed
            if [ -f "\(destDir)/bin/ollama" ] && [ ! -f "\(destPath)" ]; then
                mv "\(destDir)/bin/ollama" "\(destPath)"
            fi
            chmod +x "\(destPath)"
            """

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Task { @MainActor in completion(.failure(error)) }
                return
            }

            if process.terminationStatus != 0 {
                let raw = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    completion(.failure(NSError(
                        domain: "OllamaManager", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: msg.isEmpty
                            ? "Ollama install failed (status \(process.terminationStatus))."
                            : msg]
                    )))
                }
                return
            }

            Task { @MainActor in
                progress("Ollama installed.")
                completion(.success(()))
            }
        }
    }

    // MARK: - Helpers

    private func ollamaBinary() -> String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "\(home)/.ollama/bin/ollama"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Streaming delegate for /api/pull

private final class PullStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let tag: String
    private let onProgress: @MainActor (Double) -> Void
    private let onCompletion: @MainActor (Result<Void, Error>) -> Void
    private var buffer = Data()
    private var lastReportedProgress: Double = 0
    var session: URLSession?  // retained so ARC doesn't cancel the task

    init(
        tag: String,
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        self.tag = tag
        self.onProgress = progress
        self.onCompletion = completion
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        buffer.append(data)
        let newline = Data("\n".utf8)
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            process(line: lineData)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Task { @MainActor [weak self] in self?.onCompletion(.failure(error)) }
        } else {
            Task { @MainActor [weak self] in self?.onCompletion(.success(())) }
        }
    }

    private func process(line: Data) {
        guard !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        let status = json["status"] as? String ?? ""
        if status == "success" {
            Task { @MainActor [weak self] in self?.onProgress(1.0) }
        } else if let total = (json["total"] as? Double) ?? (json["total"] as? Int).map(Double.init),
                  let completed = (json["completed"] as? Double) ?? (json["completed"] as? Int).map(Double.init),
                  total > 0 {
            let ratio = min(0.97, completed / total)
            // Throttle to 1% increments to avoid excessive UI updates.
            if ratio - lastReportedProgress >= 0.01 {
                lastReportedProgress = ratio
                Task { @MainActor [weak self] in self?.onProgress(ratio) }
            }
        }
    }
}
