import Foundation

/// One saved conversation. `sessionID` lets `claude --resume` continue it with full context.
struct ChatRecord: Codable, Identifiable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var sessionID: String?
    var totalCost: Double
    var messages: [ClaudeSession.Message]
    // Optional: a chat that doesn't decode disappears from the history.
    /// Last message of the model: a branch from the next request starts here.
    var point: String? = nil
    /// The chat is a branch whose first request hasn't got its own session yet.
    var branch: ClaudeSession.Base? = nil
}

/// Chats live in ~/Library/Application Support/TrackTasks/chats/<folder-key>/<id>.json —
/// outside the projects, so nothing leaks into git.
enum ChatHistory {
    static let keepPerFolder = 60

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TrackTasks/chats", isDirectory: true)
    }

    static func dir(for cwd: URL, in root: URL = root) -> URL {
        let key = cwd.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "__")
        return root.appendingPathComponent(key.isEmpty ? "_root" : key, isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first.
    static func list(cwd: URL, in root: URL = root) -> [ChatRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir(for: cwd, in: root), includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    /// Claude sessions of every saved chat, all folders. Reads files: call off the main thread.
    nonisolated static func sessionIDs(in root: URL = root) -> [String] {
        struct Head: Decodable { var sessionID: String? }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Head.self, from: Data(contentsOf: $0)).sessionID }
    }

    static func save(_ r: ChatRecord, cwd: URL, in root: URL = root) {
        let d = dir(for: cwd, in: root)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(r) else { return }
        try? data.write(to: d.appendingPathComponent("\(r.id.uuidString).json"), options: .atomic)
    }

    static func delete(_ id: UUID, cwd: URL, in root: URL = root) {
        try? FileManager.default.removeItem(at: dir(for: cwd, in: root).appendingPathComponent("\(id.uuidString).json"))
    }

    /// Drop the oldest chats beyond the limit.
    static func prune(_ list: [ChatRecord], cwd: URL, in root: URL = root) -> [ChatRecord] {
        guard list.count > keepPerFolder else { return list }
        for r in list[keepPerFolder...] { delete(r.id, cwd: cwd, in: root) }
        return Array(list.prefix(keepPerFolder))
    }
}
