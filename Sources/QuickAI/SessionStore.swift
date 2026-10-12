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
        do {
            let data = try enc.encode(meta)
            try data.write(to: sidecarURL(id: meta.id), options: .atomic)
        } catch {
            Debug.log("SessionStore.save FAILED for \(meta.id): \(error)")
        }
    }

    static func load(id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: sidecarURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    /// Most recent sessions first, excluding `excludeId`. Orders by file
    /// modification date and decodes only until `limit` sessions are found,
    /// instead of parsing every saved transcript each time a menu opens.
    static func recent(limit: Int, excludeId: String?) -> [SessionMeta] {
        let fm = FileManager.default
        let suffix = ".qai.json"
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .map { url -> (url: URL, date: Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.date > $1.date }
        var metas: [SessionMeta] = []
        for f in files {
            if metas.count >= limit { break }
            // The file name is the chat id, so the excluded chat is skipped
            // without decoding it.
            let name = f.url.lastPathComponent
            if let excludeId, name == excludeId + suffix { continue }
            guard let data = try? Data(contentsOf: f.url),
                  let meta = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }
            if let excludeId, meta.id == excludeId { continue }
            metas.append(meta)
        }
        metas.sort { $0.updated > $1.updated }
        return metas
    }
}
