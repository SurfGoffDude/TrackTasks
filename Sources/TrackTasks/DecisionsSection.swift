import SwiftUI
import TrackTasksCore

/// Decisions of `docs/decisions/*.md` linked to the task, with status change, linking and creation.
struct DecisionsSection: View {
    @Binding var task: TaskItem
    let project: Project
    @State private var all: [Decision] = []
    @State private var newTitle = ""
    @State private var failure = ""

    private var dir: URL { project.url.appendingPathComponent(Decision.folder, isDirectory: true) }

    var body: some View {
        let linked = Decision.linked(to: task.fileName, body: task.body, in: all)
        let others = all.filter { d in !linked.contains { $0.id == d.id } }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").foregroundStyle(.orange)
                Text("Решения").font(.headline)
                Spacer()
                if !linked.isEmpty { Text("\(linked.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            ForEach(linked) { d in
                HStack(spacing: 8) {
                    Text(d.title).lineLimit(1)
                    Text(d.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Menu(d.status?.rawValue ?? (d.statusText.isEmpty ? "без статуса" : d.statusText)) {
                        ForEach(Decision.Status.allCases, id: \.self) { st in
                            Button(st.rawValue) { edit(d) { Decision.settingStatus($0, st) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button { edit(d) { Decision.unlinkingTask($0, task.fileName) } } label: { Image(systemName: "link.badge.plus").rotationEffect(.degrees(180)) }
                        .buttonStyle(.plain).help("Отвязать от задачи")
                }
            }
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("Новое решение…", text: $newTitle).textFieldStyle(.plain).onSubmit(create)
                if !others.isEmpty {
                    Menu("Привязать") {
                        ForEach(others) { d in Button(d.title) { edit(d) { Decision.linkingTask($0, task.fileName) } } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 14))
        .task(id: project.url) { await reload() }
    }

    private func reload() async {
        let dir = dir
        all = await Task.detached {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.sorted()
            return names.compactMap { n in
                (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)).map { Decision.parse($0, fileName: n) }
            }
        }.value
    }

    /// Edits the file on disk (re-read first, so manual edits stay), then reloads.
    private func edit(_ d: Decision, _ f: @escaping @Sendable (String) -> String) {
        let url = dir.appendingPathComponent(d.fileName)
        Task {
            failure = await Task.detached { () -> String in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "Не удалось прочитать \(url.lastPathComponent)" }
                let new = f(text)
                guard new != text else { return "" }
                do { try new.write(to: url, atomically: true, encoding: .utf8); return "" }
                catch { return "Не удалось сохранить \(url.lastPathComponent): \(error.localizedDescription)" }
            }.value
            await reload()
        }
    }

    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTitle = ""
        let dir = dir, taskName = task.fileName
        let slug = Decision.slug(title)
        Task {
            failure = await Task.detached { () -> String in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let data = Data(Decision.make(title: title, tasks: [taskName]).utf8)
                    var name = slug + ".md", n = 2
                    while true {
                        do { try data.write(to: dir.appendingPathComponent(name), options: .withoutOverwriting); return "" }
                        catch CocoaError.fileWriteFileExists { name = "\(slug)-\(n).md"; n += 1 }
                    }
                } catch { return "Не удалось создать решение: \(error.localizedDescription)" }
            }.value
            await reload()
        }
    }
}
