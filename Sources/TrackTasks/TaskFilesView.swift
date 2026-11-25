import SwiftUI
import TrackTasksCore

extension TaskFiles {
    /// Reads the project's file list off the main thread. New files that aren't in git yet count too.
    static func suggest(plan: String, in project: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let out = Worktrees.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: project)
            return suggest(plan: plan, known: out.ok ? out.out.split(separator: "\0").map(String.init) : [])
        }.value
    }
}

/// `files:` in the task sheet; «Из плана» only fills the field — the user saves it with the task.
struct TaskFilesRow: View {
    @Binding var task: TaskItem
    let project: Project
    @State private var text = ""
    @State private var found = ""

    private var bad: [String] { task.files.filter { !TaskFiles.isValid($0) } }

    var body: some View {
        HStack(spacing: 8) {
            Label("Файлы", systemImage: "doc.on.doc").foregroundStyle(.secondary)
            TextField("не указаны", text: $text)
                .textFieldStyle(.roundedBorder)
                .help("Файлы и папки, которые задача изменит, через запятую. Задачи с общими файлами не идут параллельно")
                .onChange(of: text) { _, new in
                    let list = TaskFiles.split(new)
                    if list != task.files { task.files = list }
                }
                .onChange(of: task.files, initial: true) { _, new in
                    if TaskFiles.split(text) != new { text = new.joined(separator: ", ") }
                }
            if !bad.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Нужен путь внутри проекта, без «..» и «*»: " + bad.joined(separator: ", "))
            }
            if !MD.plan(task.body).isEmpty {
                Button("Из плана") {
                    let plan = MD.plan(task.body)
                    Task {
                        let list = await TaskFiles.suggest(plan: plan, in: project.url)
                        found = list.isEmpty ? "в плане нет файлов" : ""
                        let new = list.filter { !task.files.contains($0) }
                        if !new.isEmpty { task.files += new }
                    }
                }
                .help("Добавить файлы, названные в разделе «План»")
                if !found.isEmpty { Text(found).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Files named in a plan that waits for approval; written to `files:` only by the user's click.
struct PlanFilesSuggestion: View {
    @Environment(Store.self) private var store
    let job: Job
    let plan: String
    @State private var files: [String] = []

    private var task: TaskItem? {
        store.project(job.projectID)?.tasks.first { $0.id == job.taskPath }
    }

    var body: some View {
        let new = files.filter { !(task?.files.contains($0) ?? true) }
        Group {
            if !new.isEmpty {
                HStack(spacing: 8) {
                    Button("Записать файлы задачи") { write(new) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Добавить в files: — задачи с общими файлами не пойдут параллельно")
                    Text(DirtyFiles.summary(new))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(new.joined(separator: "\n"))
                }
            }
        }
        .task(id: plan) {
            files = plan.isEmpty ? [] : await TaskFiles.suggest(plan: plan, in: job.cwd)
        }
    }

    private func write(_ new: [String]) {
        guard let t = task, let id = job.projectID else { return }
        // «Одобрить» may come before the file is written.
        let before = job.files
        job.files = t.files + new
        Task { if await !store.addFiles(new, to: t, projectID: id) { job.files = before } }
    }
}
