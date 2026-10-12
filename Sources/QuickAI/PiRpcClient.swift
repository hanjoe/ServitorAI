import CryptoKit
import Foundation

protocol PiRpcClientDelegate: AnyObject {
    func piClient(_ client: PiRpcClient, didEmitText delta: String)
    func piClientDidSettle(_ client: PiRpcClient)
    func piClient(_ client: PiRpcClient, didFail error: String)
    func piClient(_ client: PiRpcClient, didUpdateSession file: String?, id: String?, name: String?)
    func piClient(_ client: PiRpcClient, toolDidFail name: String, message: String)
}

extension PiRpcClientDelegate {
    func piClient(_ client: PiRpcClient, toolDidFail name: String, message: String) {}
}

/// Manages one warm `pi --mode rpc` child process and streams its output.
/// The process is long-lived so repeated prompts avoid agent bootup cost.
final class PiRpcClient {
    weak var delegate: PiRpcClientDelegate?

    private let process = Process()
    private let writePipe = Pipe()
    private let readPipe = Pipe()
    private var buffer = Data()
    private let readerQueue = DispatchQueue(label: "quickai.rpc.reader")
    private var nextCommandId = 0
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    /// Guards `pending` + `nextCommandId` (touched from reader thread and main).
    private let lock = NSLock()

    /// Fallback text when pi gives no error detail. Only blames the Ollama key
    /// when Ollama is actually the active provider.
    private var modelFailureHint: String {
        let provider = selectedModel?.provider ?? config.provider
        return provider == "ollama-cloud"
            ? "model request failed — check OLLAMA_API_KEY in ~/.config/servitorai/config.json or switch model with ⌘M"
            : "model request failed — check ~/.config/servitorai/pi.log or switch model with ⌘M"
    }

    /// Short, stable date/time line injected into every user message. Because the
    /// RPC child stays alive for a long time, this is computed fresh per prompt
    /// rather than baked into the system prompt at spawn.
    static var dateContextPrefix: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateStyle = .full
        fmt.timeStyle = .short
        let tz = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        let date = fmt.string(from: Date())
        let iso = ISO8601DateFormatter().string(from: Date())
        return "[Context: current local date/time is \(date) (\(tz)) — \(iso.prefix(10))] "
    }

    /// The model the user picked in the app. pi falls back to its CLI default
    /// model on `new_session`, and a restarted child starts from the config
    /// default, so this is passed at spawn and re-applied whenever pi's reported
    /// model drifts from it (see `refreshState`).
    var selectedModel: (provider: String, modelId: String)?
    /// True between pi's auto_retry_start/auto_retry_end — reader-queue only.
    private var inAutoRetry = false

    private(set) var sessionFile: String?
    private(set) var sessionId: String?
    private(set) var sessionName: String?

    private let config: AppConfig
    /// Env values resolved at startup (pass:// references already replaced).
    private var resolvedEnv: [String: String]?
    /// Keys whose values came from Proton Pass — they override inherited env.
    private var passKeys: Set<String> = []
    /// Commands issued before `start()` finished (e.g. while secrets are still
    /// resolving). Flushed in order once pi is running. Guarded by `lock`.
    private var started = false
    private var queued: [Data] = []

    init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Process lifecycle

    func start(resolvedEnv: [String: String]?, passKeys: Set<String>,
               searchExtensionPath: String? = nil,
               searchToolName: String? = nil,
               searchFingerprint: String? = nil) {
        self.resolvedEnv = resolvedEnv ?? config.env
        self.passKeys = passKeys
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pi")
        let extensionsDir = Bundle.main.resourceURL?.appendingPathComponent("Extensions")
        let listExtension = extensionsDir?.appendingPathComponent("list-files.ts")
        let guardExtension = extensionsDir?.appendingPathComponent("path-guard.ts")
        func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        // Fail closed: file tools are only enabled together with the path guard
        // that blocks credential stores (~/.ssh, ~/.config/servitorai, .env …).
        let hasGuard = exists(guardExtension)
        let hasList = hasGuard && exists(listExtension)
        let activeSearchExtension: (path: String, toolName: String)? = {
            guard let path = searchExtensionPath,
                  let toolName = searchToolName,
                  let fingerprint = searchFingerprint,
                  toolName.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
                  Self.fingerprintOfFile(at: path) == fingerprint else { return nil }
            return (path, toolName)
        }()
        var toolNames: [String] = []
        if hasGuard { toolNames.append("read") }
        if hasList { toolNames.append("list_files") }
        if let activeSearchExtension, !toolNames.contains(activeSearchExtension.toolName) {
            toolNames.append(activeSearchExtension.toolName)
        }
        let availableTools = toolNames.joined(separator: ",")
        let basePrompt = config.systemPrompt.contains("You have no tools") ? AppConfig.defaultSystemPrompt : config.systemPrompt
        let toolPrompt: String
        if toolNames.isEmpty {
            toolPrompt = "You have no tools. Do not run commands or modify files."
        } else {
            let searchInstruction = activeSearchExtension.map { " Use \($0.toolName) only when web search is needed." } ?? ""
            let rules = [
                "Use them only when the user's request needs local or current information.",
                "Do not run commands or modify files.",
                "The current date and time are provided with each user message; never look them up via tools or infer them from file names, logs, backups, screenshots, or timestamps.",
                "If a tool errors or returns no results, tell the user plainly. Do not run extra read/list_files calls to 'verify' or guess the answer; use read/list_files only for paths the user mentions or URLs returned by web_search.",
            ]
            toolPrompt = "Available tools: " + toolNames.joined(separator: ", ") + ". " + rules.joined(separator: " ") + searchInstruction
        }
        var arguments = [
            "--mode", "rpc",
            // Narrow read-only tool allowlist and only explicit, vetted extensions.
        ] + (toolNames.isEmpty ? ["--no-tools"] : ["--tools", availableTools]) + [
            "--no-extensions", "--no-skills", "--no-prompt-templates",
            "--no-context-files", "--no-mcp", "--no-themes",
            "--thinking", config.thinking,
            // Let pi select from its own configured models and auth. App
            // preferences are applied only after get_available_models confirms
            // that the provider/model is available to this user.
            "--system-prompt", basePrompt + "\n" + toolPrompt,
            "--session-dir", SessionStore.dir.path,
        ]
        if hasGuard, let guardExtension { arguments += ["--extension", guardExtension.path] }
        if hasList, let listExtension { arguments += ["--extension", listExtension.path] }
        if let activeSearchExtension { arguments += ["--extension", activeSearchExtension.path] }
        process.arguments = arguments
        Debug.log("pi spawn: tools=\(availableTools.isEmpty ? "none" : availableTools) guard=\(hasGuard) list=\(hasList) search=\(activeSearchExtension?.toolName ?? "off")")
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        // Don't let an enclosing pi session (e.g. when launched from a pi shell)
        // redirect model/provider/session for this isolated chat child.
        for key in ["PI_MODEL", "PI_PROVIDER", "PI_REASONING_LEVEL", "PI_SESSION_FILE",
                    "PI_SESSION_ID", "PI_CODING_AGENT", "PI_CODING_AGENT_SESSION_DIR"] {
            env.removeValue(forKey: key)
        }
        env["PI_SKIP_VERSION_CHECK"] = "1"
        // Tells the path guard where our (possibly XDG-relocated) config lives.
        env["SERVITORAI_CONFIG_DIR"] = Paths.configDir.path
        if let extra = resolvedEnv {
            for (k, v) in extra {
                if passKeys.contains(k) {
                    env[k] = v          // explicit Pass reference always wins
                    continue
                }
                if v.hasPrefix("pass://") {
                    env.removeValue(forKey: k)  // unresolved URI — never leak it
                    continue
                }
                if env[k] == nil { env[k] = v }
            }
        }
        process.environment = env
        process.standardInput = writePipe
        process.standardOutput = readPipe
        process.standardError = Self.stderrLogFile()
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async {
                self.delegate?.piClient(self, didFail: "pi exited (status \(code), reason \(reason.rawValue))")
            }
        }

        do {
            try process.run()
        } catch {
            let msg = "Failed to start pi: \(error.localizedDescription)"
            Self.appendDiagnostic(msg)
            delegate?.piClient(self, didFail: msg)
            return
        }

        readerQueue.async { [weak self] in
            self?.readLoop()
        }

        lock.lock()
        started = true
        let backlog = queued
        queued = []
        lock.unlock()
        for data in backlog { writePipe.fileHandleForWriting.write(data) }
    }

    func stop() {
        writePipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }
    }

    private func readLoop() {
        Debug.log("readLoop started")
        while true {
            // availableData returns as soon as ANY bytes arrive; readData(ofLength:)
            // would block until 64 KB or EOF, so small RPC replies never surfaced.
            let data = readPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            consume(data)
        }
        Debug.log("readLoop ended (EOF on pi stdout)")
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // Walk the buffer with a moving offset and trim once at the end, instead
        // of shifting the remaining bytes after every line (O(n²) on bursts).
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            var lineData = buffer.subdata(in: lineStart..<newline)
            // strip optional CR
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            processLine(lineData)
            lineStart = buffer.index(after: newline)
        }
        if lineStart > buffer.startIndex {
            buffer = Data(buffer[lineStart...])   // re-base indices at 0
        }
    }

    private func processLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !data.isEmpty {
                Debug.log("processLine: FAILED to parse JSON (len=\(data.count))")
            }
            return
        }
        let type = obj["type"] as? String
        // message_update fires per token; logging it would flood the trace.
        if type != "message_update" { Debug.log("event: \(type ?? "<no type>")") }
        if type == "tool_execution_start", let name = obj["toolName"] as? String {
            Debug.log("tool: \(name)")   // arguments can contain paths/queries — not logged
        }
        if type == "tool_execution_end", let failure = toolFailure(from: obj) {
            Debug.log("tool error: \(failure.name) → \(failure.message.prefix(150))")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.piClient(self, toolDidFail: failure.name, message: failure.message)
            }
        } else if type == "tool_execution_end", let name = obj["toolName"] as? String {
            if let result = obj["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                // Tool output can contain local file content (incl. secrets) or
                // echo the user's query — only its size is logged.
                Debug.log("tool result: \(name) → (\(text.count) chars)")
            } else {
                Debug.log("tool result: \(name) → (unparsed)")
            }
        }

        switch type {
        case "response":
            if let id = obj["id"] as? String {
                lock.lock()
                let cb = pending.removeValue(forKey: id)
                lock.unlock()
                if let cb {
                    let result: Result<[String: Any], Error>
                    if obj["success"] as? Bool == true {
                        result = .success(obj)
                    } else {
                        let err = obj["error"] as? String ?? "command failed"
                        result = .failure(NSError(domain: "QuickAI.rpc", code: 1, userInfo: [NSLocalizedDescriptionKey: err]))
                    }
                    // Completions touch UI state, so always deliver them on main.
                    DispatchQueue.main.async { cb(result) }
                }
            }
        case "message_update":
            if let ev = obj["assistantMessageEvent"] as? [String: Any] {
                let evType = ev["type"] as? String
                if evType == "text_delta", let delta = ev["delta"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.piClient(self, didEmitText: delta)
                    }
                }
                if evType == "error", let err = (ev["error"] as? String) ?? (ev["reason"] as? String) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.piClient(self, didFail: "stream error: \(err)")
                    }
                }
            }
        case "message_end":
            // Provider failures arrive as an empty assistant message with
            // stopReason "error" — surface them instead of spinning forever.
            // pi's own errorMessage (e.g. "429: …usage limit…") beats a guess.
            // Attempts made by pi's automatic retry are skipped: the first
            // failure and the final result are enough.
            if let m = obj["message"] as? [String: Any],
               m["role"] as? String == "assistant",
               m["stopReason"] as? String == "error",
               !inAutoRetry {
                let detail = (m["errorMessage"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.piClient(self, didFail: detail ?? self.modelFailureHint)
                }
            }
        case "auto_retry_start":
            inAutoRetry = true
        case "auto_retry_end":
            inAutoRetry = false
            if obj["success"] as? Bool == false {
                let detail = (obj["finalError"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.piClient(self, didFail: detail ?? self.modelFailureHint)
                }
            }
        case "agent_settled":
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.piClientDidSettle(self)
            }
        default:
            break
        }
    }

    private static func fingerprintOfFile(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// pi's stderr goes to a log file for post-mortem diagnosis.
    private static func stderrLogFile() -> FileHandle {
        let url = Paths.configDir.appendingPathComponent("pi.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            return h
        }
        return FileHandle.nullDevice
    }

    /// Append a timestamped line straight to pi.log, used for failures that
    /// happen before (or without) a pi process to redirect stderr from.
    private static func appendDiagnostic(_ message: String) {
        let url = Paths.configDir.appendingPathComponent("pi.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: url.path) else { return }
        h.seekToEndOfFile()
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) { h.write(data) }
        try? h.close()
    }

    // MARK: - Commands

    private func send(_ command: [String: Any], completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        lock.lock()
        nextCommandId += 1
        let id = "c\(nextCommandId)"
        if let completion { pending[id] = completion }
        lock.unlock()
        var cmd = command
        cmd["id"] = id
        var data = (try? JSONSerialization.data(withJSONObject: cmd)) ?? Data()
        data.append(0x0A)
        lock.lock()
        if !started {
            queued.append(data)
            lock.unlock()
            Debug.log("send: queued id=\(id) type=\(command["type"] ?? "?") (pi not started yet)")
            return
        }
        lock.unlock()
        Debug.log("send: writing \(data.count) bytes, id=\(id), type=\(command["type"] ?? "?")")
        writePipe.fileHandleForWriting.write(data)
        Debug.log("send: write() returned for id=\(id)")
    }

    func prompt(_ message: String) {
        let datedMessage = Self.dateContextPrefix + message
        send(["type": "prompt", "message": datedMessage]) { [weak self] result in
            guard let self else { return }
            if case .failure(let e) = result {
                DispatchQueue.main.async {
                    self.delegate?.piClient(self, didFail: e.localizedDescription)
                }
            }
        }
    }

    func abort(completion: (() -> Void)? = nil) {
        send(["type": "abort"]) { _ in completion?() }
    }

    func newSession(completion: (() -> Void)? = nil) {
        send(["type": "new_session"]) { [weak self] _ in
            self?.refreshState { _ in completion?() }
        }
    }

    func switchSession(path: String, completion: (() -> Void)? = nil) {
        send(["type": "switch_session", "sessionPath": path]) { [weak self] _ in
            self?.refreshState { _ in completion?() }
        }
    }

    /// Models pi can currently serve with this user's auth/configuration.
    func getAvailableModels(completion: @escaping ([ModelOption]?) -> Void) {
        send(["type": "get_available_models"]) { result in
            guard case .success(let response) = result,
                  let data = response["data"] as? [String: Any],
                  let rawModels = data["models"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            completion(rawModels.compactMap(ModelOption.fromRPC))
        }
    }

    func refreshState(completion: (([String: Any]?) -> Void)? = nil) {
        send(["type": "get_state"]) { [weak self] result in
            guard let self else { completion?(nil); return }
            var data: [String: Any]?
            if case .success(let resp) = result { data = resp["data"] as? [String: Any] }
            let file = data?["sessionFile"] as? String
            let id = data?["sessionId"] as? String
            let name = data?["sessionName"] as? String
            self.sessionFile = file
            self.sessionId = id
            self.sessionName = name
            DispatchQueue.main.async {
                self.delegate?.piClient(self, didUpdateSession: file, id: id, name: name)
            }
            // pi reverts to its CLI default model on new_session (and when a
            // session without our pick is restored). Put the user's pick back
            // before anything else runs, so the label and the real model agree.
            if let wanted = self.selectedModel, let model = data?["model"] as? [String: Any],
               (model["provider"] as? String) != wanted.provider || (model["id"] as? String) != wanted.modelId {
                Debug.log("model drift: pi=\(model["provider"] as? String ?? "?")/\(model["id"] as? String ?? "?") wanted=\(wanted.provider)/\(wanted.modelId) — re-applying")
                self.send(["type": "set_model", "provider": wanted.provider, "modelId": wanted.modelId]) { _ in
                    completion?(data)
                }
            } else {
                completion?(data)
            }
        }
    }

    func setModel(provider: String, modelId: String, completion: (([String: Any]?) -> Void)? = nil) {
        let previous = selectedModel
        selectedModel = (provider, modelId)
        send(["type": "set_model", "provider": provider, "modelId": modelId]) { [weak self] result in
            var data: [String: Any]?
            if case .success(let resp) = result { data = resp["data"] as? [String: Any] }
            // pi rejected it: forget the pick — unless a newer pick has replaced it.
            if data == nil, let self, self.selectedModel?.provider == provider, self.selectedModel?.modelId == modelId {
                self.selectedModel = previous
            }
            completion?(data)
        }
    }

    func cycleModel(completion: (([String: Any]?) -> Void)? = nil) {
        send(["type": "cycle_model"]) { result in
            var data: [String: Any]?
            if case .success(let resp) = result { data = resp["data"] as? [String: Any] }
            completion?(data)
        }
    }

    /// User messages that can be forked from, oldest first (entry ids).
    func getForkMessages(completion: @escaping ([String]) -> Void) {
        send(["type": "get_fork_messages"]) { result in
            var ids: [String] = []
            if case .success(let resp) = result,
               let data = resp["data"] as? [String: Any],
               let msgs = data["messages"] as? [[String: Any]] {
                ids = msgs.compactMap { $0["entryId"] as? String }
            }
            completion(ids)
        }
    }

    /// Fork a new session from a previous user message (history before it is kept).
    func fork(entryId: String, completion: @escaping (Bool) -> Void) {
        send(["type": "fork", "entryId": entryId]) { result in
            if case .success(let resp) = result {
                let cancelled = (resp["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
                completion(!cancelled)
            } else {
                completion(false)
            }
        }
    }
}
