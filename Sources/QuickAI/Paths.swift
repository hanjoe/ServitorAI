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
}
