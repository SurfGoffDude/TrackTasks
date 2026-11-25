import SwiftUI
import TrackTasksCore

/// Unsent comments to elements of a page: ~/Library/Application Support/TrackTasks/preview-drafts/<job>/draft.json and
/// the snapshot next to it. One per task; stays until the agent has it. Sending is never started from here.
@MainActor @Observable
final class PreviewDrafts {
    static let shared = PreviewDrafts(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/preview-drafts", isDirectory: true))

    @ObservationIgnored private let dir: URL
    private var loaded: [UUID: PreviewDraft] = [:]
    @ObservationIgnored private var opened: Set<UUID> = []

    init(dir: URL) { self.dir = dir }

    /// nil until opened.
    func draft(_ job: UUID) -> PreviewDraft? { loaded[job] }

    func open(_ job: UUID) {
        guard opened.insert(job).inserted else { return }
        loaded[job] = StorageIssues.shared.load(PreviewDraft.self, from: file(job), decoder: JSONDecoder())
    }

    /// Replaces the task's draft.
    func put(_ draft: PreviewDraft, shot: Data, for job: UUID) throws {
        open(job)
        let old = loaded[job]
        try FileManager.default.createDirectory(at: folder(job), withIntermediateDirectories: true)
        try shot.write(to: shotURL(draft, job), options: .atomic)
        loaded[job] = draft
        save(job)
        if let old, old.id != draft.id { try? FileManager.default.removeItem(at: shotURL(old, job)) }
    }

    /// Text typed by the person. A changed text wasn't sent yet.
    func setComment(_ text: String, for job: UUID) {
        guard var d = loaded[job], d.comment != text, d.delivery?.state != .sending else { return }
        d.comment = text
        d.delivery = nil
        loaded[job] = d
    }

    func save(_ job: UUID) {
        guard let d = loaded[job] else { return }
        do {
            try FileManager.default.createDirectory(at: folder(job), withIntermediateDirectories: true)
            StorageIssues.shared.save(try JSONEncoder().encode(d), to: file(job))
        } catch { StorageIssues.shared.report("Не удалось сохранить комментарий к странице: \(error.localizedDescription)") }
    }

    func shot(_ job: UUID) -> Data? { loaded[job].flatMap { try? Data(contentsOf: shotURL($0, job)) } }

    func remove(_ job: UUID) {
        loaded[job] = nil
        opened.remove(job)
        let f = folder(job)
        if FileManager.default.fileExists(atPath: f.path) { try? FileManager.default.removeItem(at: f) }
    }

    func sweep(keep: Set<UUID>) {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if let id = UUID(uuidString: n), !keep.contains(id) { remove(id) }
        }
    }

    /// A repeated task has another id.
    func move(from old: UUID, to new: UUID) {
        guard FileManager.default.fileExists(atPath: folder(old).path) else { return }
        loaded[new] = loaded.removeValue(forKey: old)
        if opened.remove(old) != nil { opened.insert(new) }
        try? FileManager.default.moveItem(at: folder(old), to: folder(new))
    }

    // MARK: Delivery

    func markSent(_ job: UUID, _ id: UUID, reply: UUID) {
        open(job)
        guard var d = loaded[job], d.id == id else { return }
        d.delivery = DiffDelivery(reply: reply, state: .sending, maybeBefore: d.delivery?.state == .unclear || d.delivery?.maybeBefore == true ? true : nil)
        loaded[job] = d
        save(job)
    }

    /// nil = the agent has it. A draft changed or replaced since then stays.
    func settle(_ job: UUID, _ id: UUID, reply: UUID, _ state: DiffDelivery.State?) {
        open(job)
        guard var d = loaded[job], d.id == id, d.delivery?.reply == reply else { return }
        guard let state else { return remove(job) }
        let before = d.delivery?.maybeBefore == true
        d.delivery?.state = state == .failed && before ? .unclear : state
        loaded[job] = d
        save(job)
    }

    private func folder(_ job: UUID) -> URL { dir.appendingPathComponent(job.uuidString, isDirectory: true) }
    private func file(_ job: UUID) -> URL { folder(job).appendingPathComponent("draft.json") }
    private func shotURL(_ d: PreviewDraft, _ job: UUID) -> URL { folder(job).appendingPathComponent(d.shotName) }
}
