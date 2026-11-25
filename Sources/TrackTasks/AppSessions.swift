import Foundation
import TrackTasksCore

/// Ids of all Claude sessions the app started (queue, chat, one-shot requests), forks included.
/// Stored in Application Support, outside the projects.
@Observable @MainActor
final class AppSessions {
    static let shared = AppSessions(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/app-sessions.json"))
    /// The part of them the user started in the chat. A file of its own: an older version of the app must still read
    /// app-sessions.json.
    static let chats = AppSessions(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/chat-sessions.json"))
    private(set) var ids: Set<String>
    @ObservationIgnored private let url: URL

    init(url: URL) {
        self.url = url
        ids = Set(StorageIssues.shared.load([String].self, from: url, decoder: JSONDecoder()) ?? [])
    }

    func add(_ id: String) { add([id]) }

    func add(_ new: [String]) {
        let fresh = Set(new).subtracting(ids).subtracting([""])
        guard !fresh.isEmpty else { return }
        ids.formUnion(fresh)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        do { StorageIssues.shared.save(try e.encode(ids.sorted()), to: url) }
        catch { StorageIssues.shared.report("Не удалось закодировать список сессий: \(error.localizedDescription)") }
    }
}
