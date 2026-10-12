import Foundation

/// Lightweight, always-on diagnostic trace. Appends timestamped lines to
/// ~/.config/servitorai/debug.log so failures can be understood after the
/// fact without attaching a debugger. Capped so it can't grow unbounded.
///
/// Log lengths, names and hosts — never user text, tool arguments or tool
/// output. The file is owner-only (0600) regardless.
enum Debug {
    private static let url = Paths.configDir.appendingPathComponent("debug.log")
    private static let lock = NSLock()
    private static let maxBytes: UInt64 = 512 * 1024
    // One handle kept open for the process lifetime; guarded by `lock`.
    private static var handle: FileHandle?
    private static var size: UInt64 = 0

    private static func open() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: url.path) else { return nil }
        size = h.seekToEndOfFile()
        return h
    }

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { handle = open() }
        guard let h = handle else { return }
        // Rotate by starting over once the cap is exceeded.
        if size > maxBytes {
            try? h.close()
            try? FileManager.default.removeItem(at: url)
            handle = open()
            guard handle != nil else { return }
        }
        guard let data = "[\(Date())] \(message)\n".data(using: .utf8) else { return }
        handle?.write(data)
        size += UInt64(data.count)
    }
}
