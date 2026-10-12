import Foundation

/// Central filesystem locations. Config and sessions live under the XDG
/// config dir (~/.config/quickai) so the app is dotfile-friendly.
enum Paths {
    static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? home.appendingPathComponent(".config").path
        return URL(fileURLWithPath: xdg).appendingPathComponent("servitorai", isDirectory: true)
    }

    static var configFile: URL { configDir.appendingPathComponent("config.json") }

    static var sessionsDir: URL {
        let d = configDir.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Config, logs and chat history can hold API keys and private
    /// conversations, so they must be owner-only. New files get this from the
    /// process umask (see main.swift); this also tightens files and
    /// directories created by earlier versions.
    static func hardenPermissions() {
        let fm = FileManager.default
        func chmod(_ url: URL, _ mode: Int) {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let dir = configDir
        guard fm.fileExists(atPath: dir.path) else { return }
        chmod(dir, 0o700)
        for sub in [dir, sessionsDir] {
            chmod(sub, 0o700)
            let entries = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                chmod(entry, isDir ? 0o700 : 0o600)
            }
        }
    }
}
