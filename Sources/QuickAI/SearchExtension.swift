import CryptoKit
import Foundation

/// A user-installed pi extension or npm package containing a tool that looks
/// intended for web search. Loading it executes arbitrary extension code with
/// pi's user permissions, so callers must obtain explicit consent before using
/// it.
struct SearchExtensionCandidate: Equatable {
    let path: String
    let toolName: String
    let description: String
    let fingerprint: String
    /// Package name for npm-installed pi packages (nil for plain extension files).
    let packageName: String?

    var displayName: String {
        let source = packageName ?? URL(fileURLWithPath: path).lastPathComponent
        return "\(toolName) — \(source)"
    }

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

    static var extensionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions", isDirectory: true)
    }

    static var packagesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/npm/node_modules", isDirectory: true)
    }

    /// All search-like candidates: extension files in ~/.pi/agent/extensions
    /// plus tools exposed by installed pi npm packages.
    static func discover() -> [SearchExtensionCandidate] {
        var candidates = discover(in: extensionsRoot) + discoverPackages(in: packagesRoot)
        // Prefer a tool literally named web_search so the default pick is the
        // canonical search tool when a package registers several.
        candidates.sort {
            if ($0.toolName == "web_search") != ($1.toolName == "web_search") {
                return $0.toolName == "web_search"
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return candidates
    }

    /// Pi loads direct source files and subdirectories with index.ts/js. Scan
    /// only those entry points; never execute candidates during discovery.
    static func discover(in root: URL) -> [SearchExtensionCandidate] {
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
                let candidate = makeCandidate(path: source.path, toolName: name,
                                              description: description, packageName: nil)
                if let candidate { found["\(source.path)#\(name)"] = candidate }
            }
        }
        return found.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Scan installed pi npm packages (~/.pi/agent/npm/node_modules) for
    /// search-like tools. A package is considered only when its package.json
    /// declares a `pi.extensions` entry-point list; each entry (file or
    /// directory with index.js/index.ts) is read as source, never executed.
    static func discoverPackages(in root: URL) -> [SearchExtensionCandidate] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var packageDirs: [URL] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            if entry.lastPathComponent.hasPrefix("@") {
                // Scoped packages: one level deeper.
                if let scoped = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) {
                    packageDirs.append(contentsOf: scoped.filter { dir in
                        (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    })
                }
            } else {
                packageDirs.append(entry)
            }
        }

        var found: [String: SearchExtensionCandidate] = [:]
        for packageDir in packageDirs.sorted(by: { $0.path < $1.path }) {
            let manifest = packageDir.appendingPathComponent("package.json")
            guard let manifestData = try? Data(contentsOf: manifest),
                  let manifestObj = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let piManifest = manifestObj["pi"] as? [String: Any],
                  let extensionEntries = piManifest["extensions"] as? [String],
                  let packageName = manifestObj["name"] as? String else { continue }

            for source in extensionEntries.flatMap({ entry -> [URL] in
                entrySources(for: packageDir.appendingPathComponent(entry))
            }) {
                guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
                for (name, description) in registeredTools(in: text) {
                    let candidate = makeCandidate(path: source.path, toolName: name,
                                                  description: description, packageName: packageName)
                    if let candidate { found["\(source.path)#\(name)"] = candidate }
                }
            }
        }
        return found.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Resolve a pi.extensions manifest entry to concrete source files:
    /// a directory yields index.js / index.ts; a file yields itself.
    private static func entrySources(for entry: URL) -> [URL] {
        let fm = FileManager.default
        let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            return ["index.js", "index.ts"].map { entry.appendingPathComponent($0) }
                .filter { fm.isReadableFile(atPath: $0.path) }
        }
        return fm.isReadableFile(atPath: entry.path) ? [entry] : []
    }

    private static func makeCandidate(path: String, toolName: String, description: String,
                                       packageName: String?) -> SearchExtensionCandidate? {
        let searchable = (toolName + " " + description).lowercased()
        guard toolName.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil,
              !coreToolNames.contains(toolName.lowercased()),
              // get_search_content & friends also mention "search"; they are
              // retrieval helpers, not search tools, so keep the offer list clean.
              !toolName.lowercased().contains("content"),
              searchTerms.contains(where: searchable.contains),
              let fingerprint = SearchExtensionCandidate.fingerprintOfFile(at: path) else { return nil }
        return SearchExtensionCandidate(path: path, toolName: toolName,
                                        description: String(description.prefix(240)),
                                        fingerprint: fingerprint, packageName: packageName)
    }

    private static func registeredTools(in source: String) -> [(String, String)] {
        let marker = "registerTool"
        var searchStart = source.startIndex
        var results: [(String, String)] = []
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            let tail = source[markerRange.upperBound...]
            let end = tail.range(of: marker)?.lowerBound ?? source.endIndex
            let block = String(source[markerRange.upperBound..<end])
            var name = firstCapture(#"name\s*:\s*["']([^"']+)["']"#, in: block) ?? ""
            if name.isEmpty {
                // Some packages register tools through an indirection, e.g.
                // `name: toolNames.webSearch`. Resolve the property against a
                // `<prop>: "tool_name"` mapping declared anywhere in the source
                // (pi-web-access's DEFAULT_TOOL_NAMES works this way).
                if let prop = firstCapture(#"name\s*:\s*[A-Za-z_$][\w$]*\.([A-Za-z_$][\w$]*)"#, in: block) {
                    name = firstCapture(#""# + prop + #"\s*:\s*["']([^"']+)["']"#, in: source) ?? ""
                }
            }
            if !name.isEmpty {
                let description = firstCapture(#"description\s*:\s*["'`]([^"'`]+)["'`]"#, in: block) ?? ""
                results.append((name, description))
            }
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