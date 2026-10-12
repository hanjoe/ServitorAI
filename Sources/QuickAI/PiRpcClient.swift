import Foundation

protocol PiRpcClientDelegate: AnyObject {
    func piClient(_ client: PiRpcClient, didEmitText delta: String)
    func piClientDidSettle(_ client: PiRpcClient)
    func piClient(_ client: PiRpcClient, didFail error: String)
    func piClient(_ client: PiRpcClient, didUpdateSession file: String?, id: String?, name: String?)
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

    private static let modelFailureHint = "model request failed — paste a real OLLAMA_API_KEY into ~/.config/servitorai/config.json or switch model with ⌘M"

    private(set) var sessionFile: String?
    private(set) var sessionId: String?
    private(set) var sessionName: String?

    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Process lifecycle

    func start() {
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pi")
        process.arguments = [
            "--mode", "rpc",
            // Pure chat: no tools and nothing from the user's pi setup. Verified
            // empirically: with these flags pi loads 0 extensions / 0 commands.
            "--no-tools",
            "--no-extensions", "--no-skills", "--no-prompt-templates",
            "--no-context-files", "--no-mcp", "--no-themes",
            "--thinking", config.thinking,
            "--provider", config.provider,
            "--model", config.model,
            "--system-prompt", config.systemPrompt,
            "--session-dir", SessionStore.dir.path,
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        // Don't let an enclosing pi session (e.g. when launched from a pi shell)
        // redirect model/provider/session for this isolated chat child.
        for key in ["PI_MODEL", "PI_PROVIDER", "PI_REASONING_LEVEL", "PI_SESSION_FILE",
                    "PI_SESSION_ID", "PI_CODING_AGENT", "PI_CODING_AGENT_SESSION_DIR"] {
            env.removeValue(forKey: key)
        }
        env["PI_SKIP_VERSION_CHECK"] = "1"
        if let extra = config.env {
            for (k, v) in extra where env[k] == nil {
                env[k] = v
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
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            // strip optional CR
            var lineData = line
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            processLine(lineData)
        }
    }

    private func processLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                Debug.log("processLine: FAILED to parse JSON (len=\(data.count)): \(s.prefix(200))")
            }
            return
        }
        let type = obj["type"] as? String
        // message_update fires per token; logging it would flood the trace.
        if type != "message_update" { Debug.log("event: \(type ?? "<no type>")") }

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
            if let m = obj["message"] as? [String: Any],
               m["role"] as? String == "assistant",
               m["stopReason"] as? String == "error" {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.piClient(self, didFail: Self.modelFailureHint)
                }
            }
        case "auto_retry_end":
            if obj["success"] as? Bool == false {
                let err = obj["finalError"] as? String ?? Self.modelFailureHint
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.piClient(self, didFail: err)
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

    /// pi's stderr goes to a log file for post-mortem diagnosis.
    private static func stderrLogFile() -> FileHandle {
        let url = Paths.configDir.appendingPathComponent("pi.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
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
            fm.createFile(atPath: url.path, contents: nil)
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
        Debug.log("send: writing \(data.count) bytes, id=\(id), type=\(command["type"] ?? "?")")
        writePipe.fileHandleForWriting.write(data)
        Debug.log("send: write() returned for id=\(id)")
    }

    func prompt(_ message: String) {
        send(["type": "prompt", "message": message]) { [weak self] result in
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
            completion?(data)
        }
    }

    func setModel(provider: String, modelId: String, completion: (([String: Any]?) -> Void)? = nil) {
        send(["type": "set_model", "provider": provider, "modelId": modelId]) { result in
            var data: [String: Any]?
            if case .success(let resp) = result { data = resp["data"] as? [String: Any] }
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
