import Foundation

/// Lightweight, always-on diagnostic trace. Appends timestamped lines to
/// ~/.config/servitorai/debug.log so failures can be understood after the
/// fact without attaching a debugger.
enum Debug {
    private static let url = Paths.configDir.appendingPathComponent("debug.log")
    private static let lock = NSLock()

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? h.close() }
        h.seekToEndOfFile()
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) { h.write(data) }
    }
}
