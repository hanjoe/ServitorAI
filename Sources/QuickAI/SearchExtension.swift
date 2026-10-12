import CryptoKit
import Foundation

/// A user-installed pi extension containing a tool that looks intended for
/// web search. Loading it executes arbitrary extension code with pi's user
/// permissions, so callers must obtain explicit consent before using it.
struct SearchExtensionCandidate: Equatable {
    let path: String
    let toolName: String
    let description: String
    let fingerprint: String

    var displayName: String { "\(toolName) — \(URL(fileURLWithPath: path).lastPathComponent)" }

    static func fingerprintOfFile(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SearchExtensionDiscovery {
    private static let supportedExtensions: Set<String> = ["ts", "js", "mjs", "cjs"]
    private static let skippedDirectories: Set<String> = ["node_modules", ".git", "disabled", "extensions-disabled"]
    private static let searchTerms = ["search", "web", "browser", "internet"]
    private static let coreToolNames: Set<String> = ["read", "bash", "edit", "write", "find", "grep", "ls", "list_files"]

    /// Pi loads direct source files and subdirectories with index.ts/js. Scan
    /// only those entry points; never execute candidates during discovery.
    static func discover(in root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/extensions", isDirectory: true)) -> [SearchExtensionCandidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var sources: [URL] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard !skippedDirectories.contains(entry.lastPathComponent) else { continue }
                for fileName in ["index.ts", "index.js"] {
                    let source = entry.appendingPathComponent(fileName)
                    if fm.isReadableFile(atPath: source.path) { sources.append(source) }
                }
            } else if supportedExtensions.contains(entry.pathExtension.lowercased()) {
                sources.append(entry)
            }
        }

        var found: [String: SearchExtensionCandidate] = [:]
        for source in sources.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
            for (name, description) in registeredTools(in: text) {
                let searchable = (name + " " + description).lowercased()
                guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil,
                      !coreToolNames.contains(name.lowercased()),
                      searchTerms.contains(where: searchable.contains),
                      let fingerprint = SearchExtensionCandidate.fingerprintOfFile(at: source.path) else { continue }
                let candidate = SearchExtensionCandidate(path: source.path, toolName: name,
                                                         description: String(description.prefix(240)), fingerprint: fingerprint)
                found["\(source.path)#\(name)"] = candidate
            }
        }
        return found.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func registeredTools(in source: String) -> [(String, String)] {
        let marker = "registerTool"
        var searchStart = source.startIndex
        var results: [(String, String)] = []
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            let tail = source[markerRange.upperBound...]
            let end = tail.range(of: marker)?.lowerBound ?? source.endIndex
            let block = String(source[markerRange.upperBound..<end])
            guard let name = firstCapture(#"name\s*:\s*[\"']([^\"']+)[\"']"#, in: block) else {
                searchStart = markerRange.upperBound
                continue
            }
            let description = firstCapture(#"description\s*:\s*[\"'`]([^\"'`]+)[\"'`]"#, in: block) ?? ""
            results.append((name, description))
            searchStart = markerRange.upperBound
        }
        return results
    }

    private static func firstCapture(_ pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}
