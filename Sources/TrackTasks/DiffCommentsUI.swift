import SwiftUI
import TrackTasksCore

/// Drafts of diff comments: ~/Library/Application Support/TrackTasks/diff-comments/<hash of source>.json.
/// They stay until the agent has them, so they survive a restart. One copy for all windows and the queue,
/// which removes delivered ones also when the window is closed. Keys are `DiffSource.key`.
@MainActor @Observable
final class DiffDrafts {
    static let shared = DiffDrafts(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackTasks/diff-comments", isDirectory: true))

    @ObservationIgnored private let dir: URL
    private var loaded: [String: [DiffComment]] = [:]

    init(dir: URL) { self.dir = dir }

    /// Empty until opened.
    func comments(_ key: String) -> [DiffComment] { loaded[key] ?? [] }

    func open(_ key: String) {
        guard loaded[key] == nil else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        loaded[key] = StorageIssues.shared.load([DiffComment].self, from: url(key), decoder: d) ?? []
    }

    func change(_ key: String, _ body: (inout [DiffComment]) -> Void) {
        open(key)
        let old = comments(key)
        var list = old
        body(&list)
        guard list != old else { return }
        loaded[key] = list
        save(list, to: url(key))
    }

    private func url(_ key: String) -> URL { dir.appendingPathComponent(DiffComments.fileName(forKey: key)) }

    private func save(_ comments: [DiffComment], to u: URL) {
        if comments.isEmpty {
            // Don't delete a file that couldn't be read: it may hold the user's drafts.
            if !SafeJSON.isBlocked(u) { try? FileManager.default.removeItem(at: u) }
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            StorageIssues.shared.save(try e.encode(comments), to: u)
        } catch {
            StorageIssues.shared.report("Не удалось сохранить комментарии к diff: \(error.localizedDescription)")
        }
    }
}

/// List of drafts under the diff, with the send button.
struct DiffCommentsPanel: View {
    let comments: [DiffComment]
    let outdated: Set<UUID>
    /// Why the message can't go to the agent; nil = can.
    let blocked: String?
    let sendNote: String
    let open: (DiffComment) -> Void
    let edit: (DiffComment) -> Void
    let remove: (DiffComment) -> Void
    let send: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label("Комментарии: \(comments.count)", systemImage: "text.bubble").font(.callout.weight(.medium))
                if !outdated.isEmpty {
                    Text("устарело: \(outdated.count)").font(.caption).foregroundStyle(.orange)
                        .help("Строки с тех пор изменились или их место неясно — проверь, актуален ли комментарий")
                }
                Spacer()
                if !sendNote.isEmpty { Text(sendNote).font(.caption).foregroundStyle(.secondary) }
                Button("Скопировать", action: copy)
                Button("Отправить агенту", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(blocked != nil || comments.allSatisfy(\.isBlank))
                    .help(blocked ?? "Все комментарии одним сообщением в сессию задачи")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if let blocked {
                Text(blocked).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            if comments.contains(where: { $0.delivery?.state == .unclear }) {
                Label("Доставка не подтверждена: отмеченные комментарии агент мог уже получить. Сами они повторно не уйдут — проверь ответ агента.",
                      systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            List(comments) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: outdated.contains(c.id) ? "exclamationmark.circle" : "text.bubble")
                        .foregroundStyle(outdated.contains(c.id) ? .orange : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\((c.path as NSString).lastPathComponent):\(c.lines)" + (c.side == .old ? " (было)" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(c.text).lineLimit(3)
                        if outdated.contains(c.id) {
                            Text("Строки изменились после комментария или их место неясно").font(.caption).foregroundStyle(.orange)
                        }
                        switch c.delivery?.state {
                        case .sending: Text("Отправляется — удалится, когда агент начнёт ход").font(.caption).foregroundStyle(.secondary)
                        case .unclear: Text("Возможно, уже отправлен").font(.caption).foregroundStyle(.orange)
                        case .failed: Text("Не отправлен").font(.caption).foregroundStyle(.red)
                        case nil: EmptyView()
                        }
                    }
                    Spacer()
                    Button { edit(c) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Изменить")
                    Button { remove(c) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Удалить")
                }
                .contentShape(Rectangle())
                .onTapGesture { open(c) }
            }
            .frame(height: min(CGFloat(comments.count) * 52 + 8, 190))
        }
        .background(.bar)
    }
}

/// Sheet to write or change one comment.
struct DiffCommentEditor: View {
    @State var comment: DiffComment
    let isNew: Bool
    /// Where the lines are now, if known.
    var lines: String?
    let save: (DiffComment) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "Новый комментарий" : "Комментарий").font(.headline)
            Text("\(comment.path):\(lines ?? comment.lines)" + (comment.side == .old ? " (старая версия)" : ""))
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                Text(comment.snippet.joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(maxHeight: 110)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $comment.text)
                .font(.body)
                .frame(minHeight: 90)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save(comment); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
