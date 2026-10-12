import Foundation

/// Resolves `pass://` secret references from the app's config into real
/// values via the Proton Pass CLI, once at startup. Values never touch disk,
/// logs, or the pasteboard. Only the child pi process receives them.
enum Secrets {
    /// Resolves config env values. Entries starting with `pass://` are looked
    /// up via pass-cli; everything else passes through unchanged.
    /// Returns resolved values plus the names of keys that failed.
    static func resolve(_ env: [String: String]) -> (values: [String: String], passKeys: Set<String>, failed: [String]) {
        var values: [String: String] = [:]
        var passKeys: Set<String> = []
        var failed: [String] = []
        for (key, value) in env {
            guard value.hasPrefix("pass://") else {
                values[key] = value
                continue
            }
            if let resolved = fetch(uri: value) {
                values[key] = resolved
                passKeys.insert(key)
            } else {
                failed.append(key)
            }
        }
        Debug.log("secrets: resolved \(passKeys.count)/\(passKeys.count + failed.count) pass reference(s)" + (failed.isEmpty ? "" : " failed: \(failed.joined(separator: ", "))"))
        return (values, passKeys, failed)
    }

    private static func passCLIPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // GUI-launched apps have launchd's PATH — check known absolute paths.
        for candidate in ["\(home)/.local/bin/pass-cli", "/opt/homebrew/bin/pass-cli", "/usr/local/bin/pass-cli"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func fetch(uri: String) -> String? {
        guard let cli = passCLIPath() else {
            Debug.log("secrets: pass-cli not found")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["item", "view", uri]
        // The app's launchd env can hang pass-cli (verified: a minimal env
        // resolves instantly, the inherited GUI env times out).
        p.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do {
            try p.run()
        } catch {
            Debug.log("secrets: pass-cli spawn failed: \(error.localizedDescription)")
            return nil
        }
        // 8s cap so a stuck CLI can't hang app startup.
        if sem.wait(timeout: .now() + 8) == .timedOut {
            p.terminate()
            Debug.log("secrets: pass-cli timed out")
            return nil
        }
        guard p.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Debug.log("secrets: pass-cli exit=\(p.terminationStatus) err=\(err.prefix(150))")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            Debug.log("secrets: pass-cli exit=0 empty stdout err=\(err.prefix(150))")
            return nil
        }
        return out
    }
}