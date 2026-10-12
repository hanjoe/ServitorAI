import Foundation

@main
enum SearchExtensionSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-extension-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let search = root.appendingPathComponent("search.ts")
        try """
        export default function (pi: any) {
          pi.registerTool({
            name: "web_search",
            description: "Search the web for current information",
          });
        }
        """.write(to: search, atomically: true, encoding: .utf8)
        let unrelated = root.appendingPathComponent("files.ts")
        try """
        export default function (pi: any) {
          pi.registerTool({ name: "list_local_files", description: "List files in a directory" });
        }
        """.write(to: unrelated, atomically: true, encoding: .utf8)

        let found = SearchExtensionDiscovery.discover(in: root)
        expect(found.count == 1, "only search-like registered tools are offered")
        expect(found.first?.toolName == "web_search", "registered search tool name found")
        expect(found.first.map { URL(fileURLWithPath: $0.path).standardizedFileURL == search.standardizedFileURL } ?? false,
               "extension source path retained")
        expect(found.first?.fingerprint == SearchExtensionCandidate.fingerprintOfFile(at: search.path),
               "consent fingerprint is stable")

        try "// changed after approval\n".write(to: search, atomically: true, encoding: .utf8)
        expect(found.first?.fingerprint != SearchExtensionCandidate.fingerprintOfFile(at: search.path),
               "changed extension source requires renewed consent")

        let actual = SearchExtensionDiscovery.discover()
        print("Installed search candidates: \(actual.map(\.displayName).joined(separator: ", "))")
        print("PASS: search-extension discovery checks complete")
    }

    private static func expect(_ condition: Bool, _ label: String) {
        guard condition else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
