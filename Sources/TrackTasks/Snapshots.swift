import SwiftUI
import TrackTasksCore
import UniformTypeIdentifiers

/// Gists made by the app. Kept apart from the queue: a cleared job must not take the link needed to delete its gist.
@Observable @MainActor
final class SnapshotStore {
    static let shared = SnapshotStore()
    private(set) var items: [GistLink] = []
    @ObservationIgnored private let url: URL
    /// Runs `gh`; tests pass their own.
    @ObservationIgnored let gh: @Sendable (_ args: [String], _ input: String?) -> Worktrees.Result

    nonisolated static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/snapshots.json")
    }

    init(url: URL = SnapshotStore.storeURL,
         gh: @escaping @Sendable ([String], String?) -> Worktrees.Result = {
             GitHubCLI.run($0, in: FileManager.default.temporaryDirectory, input: $1)
         }) {
        self.url = url
        self.gh = gh
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        items = StorageIssues.shared.load([GistLink].self, from: url, decoder: d) ?? []
    }

    /// Error text, nil = published.
    fileprivate func create(_ text: String, job: UUID, title: String) async -> String? {
        let gh = gh, body = GistAPI.createBody(text)
        let r = await Task.detached { gh(GistAPI.createArgs, body) }.value
        guard r.ok, let g = GistAPI.parseCreated(r.out) else {
            return (r.ok ? "Не разобран ответ GitHub" : r.message) + "\nGist мог создаться — проверь gist.github.com перед повтором."
        }
        items.append(GistLink(id: g.id, url: g.url, job: job, title: title))
        save()
        return nil
    }

    func delete(_ g: GistLink) async -> String? {
        guard let args = GistAPI.deleteArgs(g.id) else { return "Неверный id gist" }
        let gh = gh
        let r = await Task.detached { gh(args, nil) }.value
        guard r.ok else {
            // Also what GitHub says to another account: the link is not dropped by itself.
            return r.message.contains("HTTP 404")
                ? "GitHub не нашёл gist: он уже удалён или создан другим аккаунтом gh. Проверь ссылку." : r.message
        }
        forget(g)
        return nil
    }

    func forget(_ g: GistLink) {
        items.removeAll { $0.id == g.id }
        save()
    }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        do { StorageIssues.shared.save(try e.encode(items), to: url) }
        catch { StorageIssues.shared.report("Не удалось закодировать список снимков: \(error.localizedDescription)") }
    }
}

/// Preview → question → publication. Only the text shown in the question can go out.
@Observable @MainActor
final class SnapshotDraft {
    let job: UUID
    let title: String
    var text = ""
    private(set) var secrets = 0
    private(set) var paths = 0
    private(set) var working = false
    var error = ""
    /// The exact text the user is asked about; nil = nothing may be published.
    private(set) var asked: String?
    /// The question is on screen. Apart from `asked`: the alert closes itself before its button acts.
    var asking = false
    @ObservationIgnored private let store: SnapshotStore
    @ObservationIgnored private let redactor: Redactor

    init(job: UUID, title: String, store: SnapshotStore? = nil, redactor: Redactor = Redactor()) {
        self.job = job
        self.title = title
        self.store = store ?? .shared
        self.redactor = redactor
    }

    func show(_ clean: Redactor.Output) {
        text = clean.text
        secrets = clean.secrets
        paths = clean.paths
    }

    /// Edits are cleaned too. false = something was removed just now: the user looks again first.
    func recheck() -> Bool {
        let c = redactor.clean(text)
        guard c.text != text else { return true }
        text = c.text
        secrets += c.secrets
        paths += c.paths
        error = "В правках найдены ключи или пути — вычищено, проверь текст ещё раз."
        return false
    }

    func ask() {
        guard !working else { return }
        error = ""
        guard recheck() else { return }
        asked = text
        asking = true
    }

    func cancel() {
        asked = nil
        asking = false
    }

    /// `shown`: the text of the question. Goes out at most once per question.
    func confirm(_ shown: String) async {
        guard asked == shown, !working else { return }
        asked = nil
        asking = false
        working = true
        error = await store.create(shown, job: job, title: title) ?? ""
        working = false
    }
}

extension Job {
    /// What goes into the snapshot. Reads the session file: call off the main thread.
    struct SnapshotSource: Sendable {
        var session: String?
        /// `~/.claude/projects`
        var root: URL
        var prompt: String
        var log: [String]
        var replies: [AgentReply]
        var title: String
        var project: String
        var facts: [String]
        var review: String

        func make() -> TaskSnapshot {
            if let session, let f = SessionLog.file(session: session, in: root),
               let m = try? SessionLog.conversation(path: f), !m.isEmpty {
                return TaskSnapshot(title: title, project: project, facts: facts, messages: m, review: review)
            }
            // Lines with the gear are tool calls.
            let said = log.filter { !$0.hasPrefix("⚙︎ ") }.joined(separator: "\n\n")
            var m = [SessionMessage(.user, prompt)]
            if !said.isEmpty { m.append(.init(.agent, said)) }
            for r in replies {
                m.append(.init(.user, r.text))
                if !r.answer.isEmpty { m.append(.init(.agent, r.answer)) }
            }
            return TaskSnapshot(title: title, project: project, facts: facts, messages: m, review: review, partial: true)
        }
    }

    func snapshotSource(agent: String, kind: String) -> SnapshotSource {
        SnapshotSource(session: agentID == .claude ? sessionID : nil, root: SessionBrowser.root, prompt: prompt, log: log, replies: replies,
                       title: title, project: projectName,
                       facts: [kind, agent, modelTitle ?? "", cost.text() ?? "",
                               finishedAt?.formatted(date: .numeric, time: .shortened) ?? "",
                               handedFrom.isEmpty ? "" : "до передачи: " + handedFrom],
                       review: review)
    }
}

/// Opening it uses no network; a gist is created only after the question.
struct SnapshotSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var draft: SnapshotDraft
    @State private var loaded = false

    @MainActor init(job: Job) {
        self.job = job
        _draft = State(initialValue: SnapshotDraft(job: job.id, title: job.title))
    }

    var body: some View {
        @Bindable var draft = draft
        let links = SnapshotStore.shared.items.filter { $0.job == job.id }
        VStack(alignment: .leading, spacing: 12) {
            Label("Снимок задачи · \(job.projectName)", systemImage: "square.and.arrow.up").font(.title3.bold())
            Text("Вычищено ключей: \(draft.secrets), путей: \(draft.paths). Поиск идёт по известным форматам — просмотри текст, его можно править.")
                .font(.caption).foregroundStyle(.secondary)
            if loaded {
                TextEditor(text: $draft.text)
                    .font(.caption.monospaced())
                    .frame(height: 380)
                    .disabled(draft.working)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 380)
            }
            ForEach(links) { GistRow(gist: $0) }
            if !draft.error.isEmpty {
                Text(draft.error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
            }
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(draft.working)
                Spacer()
                if draft.working { ProgressView().controlSize(.small) }
                Button("Скопировать") {
                    guard draft.recheck() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.text, forType: .string)
                }
                .disabled(empty)
                Button("Сохранить…") { save() }.disabled(empty)
                Button("Опубликовать gist…") { draft.ask() }
                    .disabled(empty || GitHubCLI.locate() == nil)
                    .help(GitHubCLI.locate() == nil ? "Не найден GitHub CLI (gh)" : "Secret gist на github.com — сначала спросит")
            }
        }
        .padding(20)
        .frame(width: 720)
        .interactiveDismissDisabled(draft.working)
        .task {
            let src = job.snapshotSource(agent: store.jobs.agentTitle(job), kind: store.jobs.kindTitle(job.kind))
            draft.show(await Task.detached { Redactor().clean(src.make().markdown) }.value)
            loaded = true
        }
        .alert("Опубликовать secret gist?", isPresented: $draft.asking, presenting: draft.asked) { t in
            Button("Отмена", role: .cancel) { draft.cancel() }
            Button("Опубликовать") { Task { await draft.confirm(t) } }
        } message: { t in
            Text("На github.com уйдёт показанный текст (\(t.utf8.count / 1024 + 1) КБ). Secret gist не виден в поиске, но доступен всем, у кого есть ссылка. После удаления у кого-то могут остаться копии.")
        }
    }

    private var empty: Bool { !loaded || draft.working || draft.text.isEmpty }

    private func save() {
        guard draft.recheck() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md"
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { draft.error = error.localizedDescription }
    }
}

/// One published gist: open, copy the link, delete.
struct GistRow: View {
    let gist: GistLink
    @State private var working = false
    @State private var error = ""
    @State private var askDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.orange)
                Text(gist.title).lineLimit(1)
                Text(gist.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if let u = URL(string: gist.url) { Link("Открыть", destination: u) }
                Button("Ссылка") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gist.url, forType: .string)
                }
                .help("Скопировать ссылку")
                Button("Удалить", role: .destructive) { askDelete = true }.disabled(working)
            }
            if !error.isEmpty {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
                    Button("Убрать из списка") { SnapshotStore.shared.forget(gist) }
                        .help("Сам gist не удаляется")
                }
            }
        }
        .controlSize(.small)
        .confirmationDialog("Удалить gist с GitHub?", isPresented: $askDelete) {
            Button("Удалить", role: .destructive) {
                working = true
                Task {
                    error = await SnapshotStore.shared.delete(gist) ?? ""
                    working = false
                }
            }
        } message: { Text("Ссылка перестанет работать, вернуть gist нельзя.") }
    }
}

/// All published snapshots, also of jobs already cleared from the queue.
struct PublishedSnapshotsCard: View {
    var body: some View {
        let items = SnapshotStore.shared.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Опубликованные снимки: \(items.count)").font(.headline)
                ForEach(items.reversed()) { GistRow(gist: $0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}
