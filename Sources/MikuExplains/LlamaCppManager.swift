import Foundation

// MARK: - Public types

struct LlamaCppModelInfo {
    let repo: String
    let file: String
    let displayName: String
    let sizeBytes: Int64
}

struct LlamaCppModelCatalogItem {
    let id: String
    let label: String
    let tag: String
    let size: String
}

enum LlamaCppError: LocalizedError {
    case unknownModel(String)
    case serverBinaryMissing
    case serverInstallFailed(String)
    case serverLaunchFailed(String)
    case serverNotResponding
    case downloadFailed(String)
    case noApplicationSupport

    var errorDescription: String? {
        switch self {
        case .unknownModel(let tag):
            return "Unknown model: \(tag)"
        case .serverBinaryMissing:
            return "llama-server is not installed."
        case .serverInstallFailed(let msg):
            return "Could not install llama-server: \(msg)"
        case .serverLaunchFailed(let msg):
            return "llama-server failed to start: \(msg)"
        case .serverNotResponding:
            return "llama-server did not respond."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .noApplicationSupport:
            return "Could not locate Application Support."
        }
    }
}

// MARK: - Manager

/// Manages a local llama.cpp server (`llama-server`) and GGUF model
/// downloads from Hugging Face.
///
/// - Locates `llama-server` in the managed runtime dir, or downloads the
///   full llama.cpp macOS runtime from GitHub releases on first use.
/// - Pulls GGUF models with a single-shot download and atomic temp + rename.
/// - On launch, reaps any orphan server from a previous (possibly crashed)
///   run.
final class LlamaCppManager: @unchecked Sendable {
    static let shared = LlamaCppManager()

    /// Curated registry of model tags the UI can pull. Keys match the
    /// `PRESET_MODELS` list in `Resources/WebUI/app.js` so the existing
    /// dropdown IDs keep working.
    static let modelRegistry: [String: LlamaCppModelInfo] = [
        "qwen2.5:3b": .init(
            repo: "Qwen/Qwen2.5-3B-Instruct-GGUF",
            file: "qwen2.5-3b-instruct-q4_k_m.gguf",
            displayName: "Qwen 2.5 3B",
            sizeBytes: 2_000_000_000
        ),
        "qwen3.5:2b": .init(
            repo: "unsloth/Qwen3.5-2B-GGUF",
            file: "Qwen3.5-2B-Q4_K_M.gguf",
            displayName: "Qwen 3.5 2B",
            sizeBytes: 1_280_000_000
        ),
        "qwen3:4b": .init(
            repo: "Qwen/Qwen3-4B-GGUF",
            file: "Qwen3-4B-Q4_K_M.gguf",
            displayName: "Qwen 3 4B",
            sizeBytes: 2_500_000_000
        ),
        "phi3:mini": .init(
            repo: "microsoft/Phi-3-mini-4k-instruct-gguf",
            file: "Phi-3-mini-4k-instruct-q4.gguf",
            displayName: "Phi-3 Mini",
            sizeBytes: 2_300_000_000
        ),
        "mistral:7b": .init(
            repo: "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
            file: "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
            displayName: "Mistral 7B",
            sizeBytes: 4_500_000_000
        ),
    ]

    static let modelOrder = [
        "qwen2.5:3b",
        "qwen3.5:2b",
        "qwen3:4b",
        "phi3:mini",
        "mistral:7b"
    ]

    static let retiredModelAliases: [String: String] = [
        "qwen3:1.7b": "qwen3.5:2b"
    ]

    static func canonicalModelTag(for tag: String) -> String {
        retiredModelAliases[tag] ?? tag
    }

    /// Pinned llama.cpp release used as a fallback if the GitHub API
    /// call fails (e.g. rate-limited or offline). Prefer the dynamic
    /// resolver — see `resolveLatestReleaseAsset()`.
    private static let fallbackLlamaCppReleaseTag = "b9536"

    /// GitHub org that hosts llama.cpp (moved from `ggerganov/llama.cpp`).
    private static let llamaCppGitHubOwner = "ggml-org"
    private static let llamaCppGitHubRepo = "llama.cpp"

    private let fileManager = FileManager.default
    private let port: Int
    private(set) var baseURL: URL
    private var serverProcess: Process?

    private init() {
        if let envBase = ProcessInfo.processInfo.environment["MIKU_LLAMACPP_BASE"],
           let url = URL(string: envBase),
           let p = url.port {
            // Honor an explicit override (useful for debugging against
            // a manually-started server). The app still owns the process
            // it spawns — it just points at the caller's base URL.
            self.port = p
            self.baseURL = url
        } else {
            // Pick a random ephemeral port on first launch and persist
            // it, so subsequent launches reuse the same socket. This
            // guarantees no other llama-server on the system (or
            // anything else) will answer on our port.
            self.port = Self.persistedOrRandomPort()
            self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        }
    }

    /// Returns the port from `llama-server.port` if present, otherwise
    /// allocates a new ephemeral port, writes it back, and returns it.
    private static func persistedOrRandomPort() -> Int {
        let root = modelsRootStatic()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("llama-server.port", isDirectory: false)
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8),
           let p = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1024...65535).contains(p) {
            return p
        }
        // Ephemeral range: 49152–65535. Unlikely to collide.
        let p = Int.random(in: 49152...65535)
        try? Data(String(p).utf8).write(to: url, options: .atomic)
        return p
    }

    private static func modelsRootStatic() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("MikuExplains", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Filesystem layout

    private func modelsRoot() -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = support
            .appendingPathComponent("MikuExplains", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func modelDirectory(for tag: String) -> URL {
        let dir = modelsRoot().appendingPathComponent(tag, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func ggufFileURL(for tag: String) -> URL {
        modelDirectory(for: tag).appendingPathComponent("model.gguf", isDirectory: false)
    }

    func modelCatalog() -> [LlamaCppModelCatalogItem] {
        Self.modelOrder.compactMap { tag in
            guard let info = Self.modelRegistry[tag] else {
                return nil
            }

            return LlamaCppModelCatalogItem(
                id: tag,
                label: info.displayName,
                tag: tag,
                size: humanBytesStatic(info.sizeBytes)
            )
        }
    }

    private func serverRuntimeDirectoryURL() -> URL {
        modelsRoot().appendingPathComponent("llama-server-runtime", isDirectory: true)
    }

    private func serverBinaryInstallPath() -> URL {
        serverRuntimeDirectoryURL().appendingPathComponent("llama-server", isDirectory: false)
    }

    private func legacyServerBinaryInstallPath() -> URL {
        modelsRoot().appendingPathComponent("llama-server", isDirectory: false)
    }

    private func serverLogFileURL() -> URL {
        modelsRoot().appendingPathComponent("llama-server.log", isDirectory: false)
    }

    private func serverPidFileURL() -> URL {
        modelsRoot().appendingPathComponent("llama-server.pid", isDirectory: false)
    }

    private func currentModelMarkerURL() -> URL {
        modelsRoot().appendingPathComponent("llama-server.model", isDirectory: false)
    }

    // MARK: - Launch-time cleanup

    /// Reaps any orphan `llama-server` from a previous (possibly crashed)
    /// run. Pull state is intentionally not retained — downloads are
    /// not resumable, so there's nothing to reap.
    func reapStaleState() {
        reapOrphanServer()
        try? fileManager.removeItem(at: serverPidFileURL())
    }

    private func reapOrphanServer() {
        let pidURL = serverPidFileURL()
        guard let data = try? Data(contentsOf: pidURL),
              let pidString = String(data: data, encoding: .utf8),
              let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        if kill(pid, 0) == 0 {
            NSLog("LlamaCppManager: terminating orphan llama-server PID %d", pid)
            kill(pid, SIGTERM)
            for _ in 0..<15 {
                Thread.sleep(forTimeInterval: 0.2)
                if kill(pid, 0) != 0 { break }
            }
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Server binary

    var isServerBinaryInstalled: Bool {
        serverBinaryURL() != nil
    }

    private func serverBinaryURL() -> URL? {
        // Strictly our own runtime. We don't trust anything in $PATH or
        // system locations because the current macOS llama.cpp release
        // binary depends on sibling dylibs via @loader_path.
        let candidates = [serverBinaryInstallPath()]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads `llama-server` from the latest llama.cpp GitHub release
    /// if it isn't already installed in any of the search paths. Resolves
    /// the actual download URL via the GitHub Releases API (so it tracks
    /// upstream renames of the binary archive), and falls back to a
    /// pinned release tag if the API call fails. Idempotent.
    func ensureServerBinaryInstalled(
        progress: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Result<Void, LlamaCppError>) -> Void
    ) {
        if isServerBinaryInstalled {
            Task { @MainActor in completion(.success(())) }
            return
        }

        Task { @MainActor in progress("Resolving latest llama.cpp release…") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let resolved: LlamaCppRelease
            switch self.resolveLatestReleaseAsset() {
            case .success(let release):
                resolved = release
            case .failure(let error):
                // Fall back to the pinned tag + arch suffix. Try the modern
                // `.tar.gz` archive first; older releases used `.zip`.
                let arch = self.currentArchAssetName()
                let tgz = "https://github.com/\(Self.llamaCppGitHubOwner)/\(Self.llamaCppGitHubRepo)/releases/download/\(Self.fallbackLlamaCppReleaseTag)/llama-\(Self.fallbackLlamaCppReleaseTag)-bin-macos-\(arch).tar.gz"
                guard let fallbackURL = URL(string: tgz) else {
                    Task { @MainActor in completion(.failure(error)) }
                    return
                }
                NSLog("LlamaCppManager: GitHub API failed (%@) — falling back to %@", error.localizedDescription, fallbackURL.absoluteString)
                resolved = LlamaCppRelease(tag: Self.fallbackLlamaCppReleaseTag, downloadURL: fallbackURL)
            }

            Task { @MainActor in progress("Downloading llama-server \(resolved.tag) for \(self.currentArchAssetName())…") }

            self.runInstallScript(downloadURL: resolved.downloadURL, tag: resolved.tag, progress: progress, completion: completion)
        }
    }

    private func runInstallScript(
        downloadURL: URL,
        tag: String,
        progress: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Result<Void, LlamaCppError>) -> Void
    ) {
        let installDir = modelsRoot().path
        let runtimeDir = serverRuntimeDirectoryURL().path
        let installPath = serverBinaryInstallPath().path
        let legacyInstallPath = legacyServerBinaryInstallPath().path
        let url = downloadURL.absoluteString

        // Modern releases ship `.tar.gz`; older ones used `.zip`. Try tar
        // first (cheap to check the extension), fall back to unzip. The
        // binary's path inside the archive changes between releases, so
        // we use `find` to locate it instead of hardcoding layout paths.
        // Keep the whole directory containing llama-server: recent macOS
        // builds dynamically link sibling libggml/libllama dylibs via
        // @loader_path, so moving just the executable breaks startup.
        let script = """
        set -e
        workdir="\(installDir)/_llamacpp_install"
        runtime_dir="\(runtimeDir)"
        tmp_runtime="${runtime_dir}.tmp"
        rm -rf "$workdir"
        rm -rf "$tmp_runtime"
        mkdir -p "$workdir"
        mkdir -p "$tmp_runtime"
        cd "$workdir"
        url="\(url)"
        case "$url" in
            *.tar.gz|*.tgz)
                curl -fsSL "$url" -o llama.tar.gz
                tar -xzf llama.tar.gz
                rm llama.tar.gz
                ;;
            *.zip)
                curl -fsSL "$url" -o llama.zip
                unzip -q -o llama.zip
                rm llama.zip
                ;;
            *)
                echo "unsupported archive format: $url" >&2
                exit 1
                ;;
        esac
        # Locate any executable file named llama-server anywhere in the
        # extracted tree. The path has shifted between releases (e.g.
        # build/bin/llama-server, llama-server, bin/llama-server).
        found=""
        find . -type f -name 'llama-server' 2>/dev/null > candidates.txt
        while IFS= read -r candidate; do
            if [ -x "$candidate" ] || file "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
                found="$candidate"
                break
            fi
        done < candidates.txt
        if [ -z "$found" ]; then
            echo "llama-server binary not found in archive" >&2
            echo "--- extracted tree ---" >&2
            find . -maxdepth 4 -type f 2>/dev/null | head -50 >&2
            exit 1
        fi
        runtime_source="$(dirname "$found")"
        cp -R "$runtime_source"/. "$tmp_runtime"/
        chmod +x "$tmp_runtime/llama-server"
        rm -rf "$runtime_dir"
        mv "$tmp_runtime" "$runtime_dir"
        rm -f "\(legacyInstallPath)"
        rm -rf "$workdir"
        """

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
            Task { @MainActor in completion(.failure(.serverInstallFailed(error.localizedDescription))) }
            return
        }

        if process.terminationStatus != 0 {
            let raw = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                completion(.failure(.serverInstallFailed(
                    msg.isEmpty ? "Status \(process.terminationStatus)." : msg
                )))
            }
            return
        }

        if !FileManager.default.isExecutableFile(atPath: installPath) {
            Task { @MainActor in
                completion(.failure(.serverInstallFailed("Install completed but binary not executable.")))
            }
            return
        }

        Task { @MainActor in
            progress("llama-server \(tag) installed.")
            completion(.success(()))
        }
    }

    // MARK: - Release resolution

    private struct LlamaCppRelease {
        let tag: String
        let downloadURL: URL
    }

    /// Synchronously resolves the latest llama.cpp release and the macOS
    /// download URL matching this Mac's architecture. Returns the failure
    /// if the API call fails or no matching asset is present.
    private func resolveLatestReleaseAsset() -> Result<LlamaCppRelease, LlamaCppError> {
        let apiURLString = "https://api.github.com/repos/\(Self.llamaCppGitHubOwner)/\(Self.llamaCppGitHubRepo)/releases/latest"
        guard let apiURL = URL(string: apiURLString) else {
            return .failure(.serverInstallFailed("Invalid GitHub API URL"))
        }
        var request = URLRequest(url: apiURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MikuExplains", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        let dataBox = UnsafeMutableTransfer<Data?>(nil)
        let responseBox = UnsafeMutableTransfer<URLResponse?>(nil)
        let errorBox = UnsafeMutableTransfer<Error?>(nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            dataBox.value = data
            responseBox.value = response
            errorBox.value = error
            sem.signal()
        }.resume()
        sem.wait()

        if let error = errorBox.value {
            return .failure(.serverInstallFailed("GitHub API error: \(error.localizedDescription)"))
        }
        guard let data = dataBox.value else {
            return .failure(.serverInstallFailed("GitHub API returned no data"))
        }
        guard let http = responseBox.value as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (responseBox.value as? HTTPURLResponse)?.statusCode ?? -1
            return .failure(.serverInstallFailed("GitHub API returned status \(code)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            return .failure(.serverInstallFailed("Could not parse GitHub release JSON"))
        }

        let arch = currentArchAssetName()
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let dl = asset["browser_download_url"] as? String,
                  let dlURL = URL(string: dl) else { continue }
            if name.hasPrefix("llama-") && name.contains("macos-\(arch)") {
                if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".zip") {
                    return .success(LlamaCppRelease(tag: tag, downloadURL: dlURL))
                }
            }
        }
        return .failure(.serverInstallFailed("No llama-cpp macos-\(arch) asset in latest release (\(tag))."))
    }

    private func currentArchAssetName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    // MARK: - Server lifecycle

    func isServerRunning() -> Bool {
        let url = baseURL.appendingPathComponent("/health")
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

    /// Spawns `llama-server` with the given GGUF model loaded. If a server
    /// is already running but with a different model, it is restarted.
    @discardableResult
    func ensureServerRunning(modelPath: URL) -> Bool {
        switch ensureServerRunningDetailed(modelPath: modelPath) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    /// Detailed variant used by the UI so startup failures include the
    /// actual llama-server stderr log instead of collapsing to "did not start."
    @discardableResult
    func ensureServerRunningDetailed(modelPath: URL) -> Result<Void, LlamaCppError> {
        if isServerRunning() {
            if currentlyLoadedModelPath()?.standardizedFileURL.path == modelPath.standardizedFileURL.path {
                return .success(())
            }
            stopManagedServer()
        }

        guard let binary = serverBinaryURL() else {
            NSLog("LlamaCppManager: llama-server binary not found")
            return .failure(.serverBinaryMissing)
        }

        NSLog("LlamaCppManager: launching llama-server with %@", modelPath.lastPathComponent)
        try? fileManager.removeItem(at: serverLogFileURL())
        fileManager.createFile(atPath: serverLogFileURL().path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: serverLogFileURL())

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = [
            "-m", modelPath.path,
            "--port", String(port),
            "--host", "127.0.0.1",
            "-c", "8192",
            "--jinja",
            "--cache-prompt",
            "-np", "1"
        ]
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        do {
            try process.run()
            logHandle?.closeFile()
            serverProcess = process
        } catch {
            logHandle?.closeFile()
            NSLog("LlamaCppManager: failed to launch: %@", error.localizedDescription)
            return .failure(.serverLaunchFailed(error.localizedDescription))
        }

        NSLog("LlamaCppManager: llama-server PID %d", process.processIdentifier)
        try? Data(String(process.processIdentifier).utf8).write(to: serverPidFileURL())
        try? Data(modelPath.path.utf8).write(to: currentModelMarkerURL())

        // Poll /health until 200, up to 30s.
        let deadline = Date().addingTimeInterval(30)
        var attempts = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            attempts += 1
            if isServerRunning() {
                NSLog("LlamaCppManager: server up after %d polls", attempts)
                return .success(())
            }
            if !process.isRunning {
                NSLog("LlamaCppManager: llama-server exited early (status %d)", process.terminationStatus)
                try? fileManager.removeItem(at: serverPidFileURL())
                try? fileManager.removeItem(at: currentModelMarkerURL())
                let details = tailOfServerLog()
                let suffix = details.isEmpty ? "" : " \(details)"
                return .failure(.serverLaunchFailed("Exited with status \(process.terminationStatus).\(suffix)"))
            }
        }
        NSLog("LlamaCppManager: server did not respond after %d polls", attempts)
        process.terminate()
        let details = tailOfServerLog()
        let suffix = details.isEmpty ? "" : " Last log: \(details)"
        return .failure(.serverLaunchFailed("Timed out waiting for \(baseURL.appendingPathComponent("/health").absoluteString).\(suffix)"))
    }

    func stopManagedServer() {
        serverProcess?.terminate()
        serverProcess = nil
        try? fileManager.removeItem(at: serverPidFileURL())
        try? fileManager.removeItem(at: currentModelMarkerURL())
    }

    /// Spawns `llama-server` with the given model loaded in the background
    /// and leaves it running until `stopManagedServer()` is called. Safe
    /// to call multiple times — no-ops if the server is already up with
    /// the right model, and triggers a restart if the model has changed.
    /// Used to keep the server warm for the lifetime of the app so the
    /// first shortcut press doesn't pay the load cost.
    func prewarmServer(modelPath: URL, onReady: (@MainActor () -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = self?.ensureServerRunning(modelPath: modelPath) ?? false
            if ok, let onReady {
                Task { @MainActor in onReady() }
            }
        }
    }

    func latestInferenceDebugStats() -> String? {
        let log = tailOfServerLog(maxBytes: 80_000)
        guard !log.isEmpty else {
            return nil
        }

        let lines = log
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return nil
        }

        var stats: [String] = []
        if let metal = firstReadableLine(containing: "MTL0", in: lines) {
            stats.append("Metal: \(metal)")
        }
        if let system = firstReadableLine(containing: "system_info:", in: lines) {
            stats.append("System: \(system)")
        }
        if let context = lastReadableLine(containing: "new slot, n_ctx", in: lines) {
            stats.append("Context: \(context)")
        }
        if let promptEval = lastReadableLine(containing: "prompt eval time", in: lines) {
            stats.append("Prompt: \(promptEval)")
        }
        if let generation = lines.last(where: { line in
            line.contains(" eval time") && !line.contains("prompt eval time")
        }).map(readableLogLine) {
            stats.append("Generation: \(generation)")
        }
        if let total = lastReadableLine(containing: "total time", in: lines) {
            stats.append("Total: \(total)")
        }

        guard !stats.isEmpty else {
            return nil
        }

        return (["llama.cpp runtime stats:"] + stats.map { "  \($0)" }).joined(separator: "\n")
    }

    private func tailOfServerLog(maxBytes: Int = 4_000) -> String {
        guard let data = try? Data(contentsOf: serverLogFileURL()), !data.isEmpty else {
            return ""
        }
        let tail = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
        return (String(data: tail, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstReadableLine(containing needle: String, in lines: [String]) -> String? {
        lines.first { $0.contains(needle) }.map(readableLogLine)
    }

    private func lastReadableLine(containing needle: String, in lines: [String]) -> String? {
        lines.last { $0.contains(needle) }.map(readableLogLine)
    }

    private func readableLogLine(_ line: String) -> String {
        if let range = line.range(of: " - ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = line.range(of: "system_info:") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = line.range(of: "new slot,") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = line.range(of: "prompt eval time") {
            return "prompt eval time" + line[range.upperBound...]
        }
        if let range = line.range(of: "eval time") {
            return "eval time" + line[range.upperBound...]
        }
        if let range = line.range(of: "total time") {
            return "total time" + line[range.upperBound...]
        }
        if let range = line.range(of: " I ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = line.range(of: " W ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private func currentlyLoadedModelPath() -> URL? {
        guard let data = try? Data(contentsOf: currentModelMarkerURL()),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    // MARK: - Model listing

    /// Lists installed (fully downloaded) model tags by scanning the models
    /// directory for completed `model.gguf` files.
    func listInstalledModels(completion: @escaping @MainActor ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let root = self.modelsRoot()
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
                Task { @MainActor in completion([]) }
                return
            }
            let installed = entries.filter { tag in
                let gguf = root
                    .appendingPathComponent(tag, isDirectory: true)
                    .appendingPathComponent("model.gguf", isDirectory: false)
                return fm.fileExists(atPath: gguf.path)
            }
            .sorted()
            Task { @MainActor in completion(installed) }
        }
    }

    /// Removes a downloaded `model.gguf` for the given tag. Stops the
    /// managed server first when that model is currently loaded.
    func deleteInstalledModel(_ tag: String) -> Result<Void, LlamaCppError> {
        guard Self.modelRegistry[tag] != nil else {
            return .failure(.unknownModel(tag))
        }

        let ggufURL = ggufFileURL(for: tag)
        guard fileManager.fileExists(atPath: ggufURL.path) else {
            return .failure(.downloadFailed("Model not installed: \(tag)"))
        }

        if currentlyLoadedModelPath()?.standardizedFileURL.path == ggufURL.standardizedFileURL.path {
            stopManagedServer()
        }

        do {
            try fileManager.removeItem(at: ggufURL)
            let directory = modelDirectory(for: tag)
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
               contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
            return .success(())
        } catch {
            return .failure(.downloadFailed("Could not delete \(tag): \(error.localizedDescription)"))
        }
    }

    // MARK: - Model pulling

    /// Downloads a GGUF model from Hugging Face in a single shot. On
    /// failure, the temp file is auto-deleted by URLSession — nothing is
    /// left on disk. On success, the temp file is atomically moved to
    /// `<tag>/model.gguf`. No partial files, no resume state, no Range
    /// requests. If the app is force-quit or the network drops, the
    /// user re-pulls and starts over.
    func pullModel(
        _ tag: String,
        progress: @escaping @MainActor (Double, String?) -> Void,
        completion: @escaping @MainActor (Result<Void, LlamaCppError>) -> Void
    ) {
        guard let info = Self.modelRegistry[tag] else {
            Task { @MainActor in completion(.failure(.unknownModel(tag))) }
            return
        }

        let ggufURL = ggufFileURL(for: tag)
        if fileManager.fileExists(atPath: ggufURL.path) {
            Task { @MainActor in
                progress(1.0, "Already installed")
                completion(.success(()))
            }
            return
        }

        let urlString = "https://huggingface.co/\(info.repo)/resolve/main/\(info.file)"
        guard let downloadURL = URL(string: urlString) else {
            Task { @MainActor in completion(.failure(.downloadFailed("Invalid URL"))) }
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7200
        config.timeoutIntervalForResource = 7200
        let sem = DispatchSemaphore(value: 0)
        let tempBox = UnsafeMutableTransfer<URL?>(nil)
        let responseBox = UnsafeMutableTransfer<URLResponse?>(nil)
        let errorBox = UnsafeMutableTransfer<Error?>(nil)
        let downloadTempURL = modelDirectory(for: tag)
            .appendingPathComponent("model.gguf.download-\(UUID().uuidString)", isDirectory: false)
        let delegate = ModelDownloadDelegate(
            expectedSizeBytes: info.sizeBytes,
            tempFileURL: downloadTempURL,
            progress: progress,
            tempBox: tempBox,
            responseBox: responseBox,
            errorBox: errorBox,
            semaphore: sem
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: downloadURL)

        Task { @MainActor in progress(0, "Starting") }
        task.resume()
        sem.wait()
        session.finishTasksAndInvalidate()

        if let error = errorBox.value {
            // URLSession has already removed any temp file.
            Task { @MainActor in completion(.failure(.downloadFailed(error.localizedDescription))) }
            return
        }

        guard let http = responseBox.value as? HTTPURLResponse else {
            Task { @MainActor in completion(.failure(.downloadFailed("No HTTP response"))) }
            return
        }
        if http.statusCode != 200 {
            let code = http.statusCode
            Task { @MainActor in completion(.failure(.downloadFailed("Server returned status \(code)"))) }
            return
        }

        guard let tempURL = tempBox.value else {
            Task { @MainActor in completion(.failure(.downloadFailed("No file returned"))) }
            return
        }

        // Atomic move into the model directory.
        do {
            if FileManager.default.fileExists(atPath: ggufURL.path) {
                try FileManager.default.removeItem(at: ggufURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: ggufURL)
        } catch {
            // If we can't install the file, drop the temp so we don't
            // leak multi-GB downloads.
            try? FileManager.default.removeItem(at: tempURL)
            Task { @MainActor in
                completion(.failure(.downloadFailed("Install failed: \(error.localizedDescription)")))
            }
            return
        }

        Task { @MainActor in
            progress(1.0, "Ready")
            completion(.success(()))
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSizeBytes: Int64
    private let tempFileURL: URL
    private let progress: @MainActor (Double, String?) -> Void
    private let tempBox: UnsafeMutableTransfer<URL?>
    private let responseBox: UnsafeMutableTransfer<URLResponse?>
    private let errorBox: UnsafeMutableTransfer<Error?>
    private let semaphore: DispatchSemaphore

    init(
        expectedSizeBytes: Int64,
        tempFileURL: URL,
        progress: @escaping @MainActor (Double, String?) -> Void,
        tempBox: UnsafeMutableTransfer<URL?>,
        responseBox: UnsafeMutableTransfer<URLResponse?>,
        errorBox: UnsafeMutableTransfer<Error?>,
        semaphore: DispatchSemaphore
    ) {
        self.expectedSizeBytes = expectedSizeBytes
        self.tempFileURL = tempFileURL
        self.progress = progress
        self.tempBox = tempBox
        self.responseBox = responseBox
        self.errorBox = errorBox
        self.semaphore = semaphore
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSizeBytes
        let fallbackFraction = downloadTask.progress.fractionCompleted.isFinite
            ? max(0, min(1, downloadTask.progress.fractionCompleted))
            : 0
        let fallbackBytes = total > 0 ? Int64((Double(total) * fallbackFraction).rounded()) : 0
        let bytes = max(totalBytesWritten, fallbackBytes)
        let ratio = total > 0 ? min(0.97, max(0, Double(bytes) / Double(total))) : min(0.97, fallbackFraction)
        let status = modelDownloadStatus(bytes: bytes, total: total, ratio: ratio)

        Task { @MainActor in progress(ratio, status) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        responseBox.value = downloadTask.response
        do {
            try? FileManager.default.removeItem(at: tempFileURL)
            try FileManager.default.moveItem(at: location, to: tempFileURL)
            tempBox.value = tempFileURL
        } catch {
            errorBox.value = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        responseBox.value = task.response
        if errorBox.value == nil {
            errorBox.value = error
        }
        semaphore.signal()
    }
}

private func modelDownloadStatus(bytes: Int64, total: Int64, ratio: Double) -> String {
    let percent = Int((max(0, min(1, ratio)) * 100).rounded())
    guard bytes > 0 else {
        return "Starting"
    }
    guard total > 0 else {
        return "\(percent)% \(compactBytes(bytes))"
    }
    let displayBytes = min(bytes, total)
    return "\(percent)% \(compactBytes(displayBytes))/\(compactBytes(total))"
}

private func compactBytes(_ bytes: Int64) -> String {
    let value = max(0, Double(bytes))
    if value >= 1_000_000_000 {
        let gb = value / 1_000_000_000
        return gb >= 10
            ? String(format: "%.0fG", gb)
            : String(format: "%.1fG", gb)
    }

    let mb = value / 1_000_000
    if mb >= 1 {
        return String(format: "%.0fM", mb.rounded())
    }

    return "<1M"
}

private func humanBytesStatic(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
