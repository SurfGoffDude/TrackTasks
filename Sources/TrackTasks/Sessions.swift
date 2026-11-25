import Foundation
import SwiftUI

/// State of «Сессии Claude». Parsing and search run in `SessionLibrary` (off the main thread);
/// files are watched only while the screen is open.
@Observable @MainActor
final class SessionBrowser {
    static let shared = SessionBrowser()
    nonisolated static let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private(set) var results: [ClaudeSessionInfo] = []
    private(set) var progress: (done: Int, total: Int)?
    private(set) var loaded = false
    /// Session folders that exist: `claude --resume` works only from there.
    private(set) var folders: Set<String> = []
    var query = ""
    var projectFilter: String?
    private static let sourceKey = "sessionsSource"
    var sourceFilter = UserDefaults.standard.string(forKey: sourceKey).flatMap(SessionFilter.init) ?? .mine {
        didSet { UserDefaults.standard.set(sourceFilter.rawValue, forKey: Self.sourceKey) }
    }

    @ObservationIgnored private let library = SessionLibrary(root: SessionBrowser.root)
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var searchGen = 0
    @ObservationIgnored private var lastProgress = Date.distantPast

    func start() {
        guard watcher == nil else { return }
        watcher = FileWatcher(paths: [Self.root.path], latency: 5) { [weak self] events in
            guard events.contains(where: { $0.mustRescan || ($0.path.hasSuffix(".jsonl") && !$0.path.contains("/subagents/")) })
            else { return }
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
        // Chats from before the app marked their sessions.
        Task { AppSessions.chats.add(await Task.detached(priority: .utility) { ChatHistory.sessionIDs() }.value) }
    }

    func stop() { watcher = nil }

    private func refresh() async {
        await library.refresh { done, total in
            Task { @MainActor in SessionBrowser.shared.indexed(done, total) }
        }
        progress = nil
        loaded = true
        await search()
    }

    private func indexed(_ done: Int, _ total: Int) {
        // A changed file or two is not worth a progress bar.
        guard total > 20, done < total, !loaded, Date().timeIntervalSince(lastProgress) > 0.3 else { return }
        lastProgress = Date()
        progress = (done, total)
        Task { await search() }
    }

    func search() async {
        searchGen += 1
        let gen = searchGen, library = library, query = query
        let (found, dirs) = await Task.detached(priority: .userInitiated) {
            let found = await library.search(query)
            let dirs = Set(found.map(\.cwd)).filter { p in
                var isDir: ObjCBool = false
                return !p.isEmpty && FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            }
            return (found, dirs)
        }.value
        guard gen == searchGen else { return }
        if found != results { results = found }
        SessionForks.shared.resolve(found)
        if dirs != folders { folders = dirs }
    }
}

/// Links set by hand: session id → task path. Stored outside the projects.
@Observable @MainActor
final class SessionLinks {
    static let shared = SessionLinks()
    private(set) var items: [String: String] = [:]

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/session-links.json")
    }

    private init() {
        items = StorageIssues.shared.load([String: String].self, from: Self.url, decoder: JSONDecoder()) ?? [:]
    }

    func set(_ taskPath: String?, for session: String) {
        guard items[session] != taskPath else { return }
        items[session] = taskPath
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { StorageIssues.shared.save(try e.encode(items), to: Self.url) }
        catch { StorageIssues.shared.report("Не удалось закодировать привязки сессий: \(error.localizedDescription)") }
    }
}

/// Forks started from the sessions screen (terminal): child session id → parent id. A fork is first `pending`
/// (its id appears only when the CLI writes the file), then matched by `SessionFork.match`.
@Observable @MainActor
final class SessionForks {
    static let shared = SessionForks()
    private struct Saved: Codable {
        var children: [String: String] = [:]
        var pending: [SessionFork.Pending] = []
    }
    private(set) var children: [String: String] = [:]
    private var pending: [SessionFork.Pending] = []

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/session-forks.json")
    }

    private init() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let s = StorageIssues.shared.load(Saved.self, from: Self.url, decoder: d) {
            children = s.children
            pending = s.pending
        }
    }

    func started(_ parent: ClaudeSessionInfo) {
        pending.append(.init(parent: parent.id, cwd: parent.cwd, firstPrompt: parent.firstPrompt, at: Date()))
        save()
    }

    /// Match waiting forks with sessions that have appeared. Pending ones older than a day are dropped.
    func resolve(_ sessions: [ClaudeSessionInfo]) {
        guard !pending.isEmpty else { return }
        var changed = false
        var rest: [SessionFork.Pending] = []
        for p in pending {
            if let m = SessionFork.match(p, in: sessions, taken: Set(children.keys)) {
                children[m.id] = p.parent
                changed = true
            } else if Date().timeIntervalSince(p.at) < 86_400 {
                rest.append(p)
            } else {
                changed = true
            }
        }
        guard changed else { return }
        pending = rest
        save()
    }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        do { StorageIssues.shared.save(try e.encode(Saved(children: children, pending: pending)), to: Self.url) }
        catch { StorageIssues.shared.report("Не удалось закодировать ответвления сессий: \(error.localizedDescription)") }
    }
}
