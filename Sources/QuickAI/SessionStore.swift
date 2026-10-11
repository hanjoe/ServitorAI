import Foundation

struct ChatMessage: Codable {
    var role: String   // "user" or "assistant"
    var text: String
}

struct SessionMeta: Codable {
    var id: String
    var sessionFile: String
    var title: String
    var updated: Date
    var messages: [ChatMessage]
}

/// Persists lightweight sidecar metadata for chat sessions so the app can
/// list the most recent sessions and repopulate the panel on resume.
/// pi itself owns the real session context files (`.jsonl`) in the same dir.
final class SessionStore {
    static let dir: URL = Paths.sessionsDir

    private static func sidecarURL(id: String) -> URL {
        dir.appendingPathComponent(id + ".qai.json")
    }

    static func save(_ meta: SessionMeta) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(meta) {
            try? data.write(to: sidecarURL(id: meta.id), options: .atomic)
        }
    }

    static func load(id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: sidecarURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    /// Most recent sessions first, excluding `excludeId`.
    static func recent(limit: Int, excludeId: String?) -> [SessionMeta] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var metas: [SessionMeta] = []
        for f in files where f.pathExtension == "json" && f.lastPathComponent.hasSuffix(".qai.json") {
            guard let data = try? Data(contentsOf: f),
                  let meta = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }
            if let excludeId, meta.id == excludeId { continue }
            metas.append(meta)
        }
        metas.sort { $0.updated > $1.updated }
        return Array(metas.prefix(limit))
    }
}
