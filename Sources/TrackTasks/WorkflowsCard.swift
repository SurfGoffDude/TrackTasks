import AppKit
import SwiftUI
import TrackTasksCore
import UniformTypeIdentifiers

extension WorkflowFile {
    /// File problems and what is missing on this machine.
    @MainActor var allProblems: [Workflow.Problem] { problems + Self.machineWarnings(workflow) }

    @MainActor static func machineWarnings(_ w: Workflow) -> [Workflow.Problem] {
        let profiles = AgentProfileStore.current
        return w.warnings { name in
            profiles.resolve(name).flatMap { AgentRegistry.standard[$0.agent] }.map { $0.capabilities.contains(.cost) }
        }
    }
}

/// `workflows/*.md` of the project.
struct WorkflowsCard: View {
    @Environment(Store.self) private var store
    let project: Project
    @State private var editing: WorkflowDraft?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Пайплайны", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.headline)
                Spacer()
                Menu("Добавить") {
                    Button("Из шаблона «План → Код → Ревью → Исправление»") { editing = WorkflowDraft(name: "default", text: Workflow.template.serialized()) }
                    Button("Импорт из файла…", action: importFile)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
            if project.workflows.isEmpty {
                Text("Свой агент и модель на каждом шаге задачи. Слияние всегда за тобой.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(project.workflows) { row($0) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .sheet(item: $editing) { WorkflowEditor(draft: $0, project: project) }
    }

    private func row(_ f: WorkflowFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(f.name).font(.callout.monospaced())
                Text(f.workflow.steps.map { $0.title + ($0.agent.isEmpty ? "" : " (\($0.agent))") }.joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Править") { editing = WorkflowDraft(name: f.name, text: f.text, url: f.url) }
                Button("Экспорт…") { export(f) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            WorkflowProblems(problems: f.allProblems)
        }
    }

    private func importFile() {
        error = ""
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Выбери пайплайн (.md). Перед записью он откроется целиком."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch WorkflowFile.load(url) {
        case .failure(let e): error = "Импорт: " + e.message
        case .success(let f):
            let content = f.problems.filter(\.isError).map(\.message)
            guard f.workflow.lint().allSatisfy({ !$0.isError }), Workflow.parse(f.text)?.problems.contains(where: \.isError) != true else {
                error = "Импорт отклонён: " + content.joined(separator: "; ")
                return
            }
            editing = WorkflowDraft(name: AgentProfile.isValidID(f.name) ? f.name : "imported", text: f.text, imported: true)
        }
    }

    private func export(_ f: WorkflowFile) {
        error = ""
        let panel = NSSavePanel()
        panel.nameFieldStringValue = f.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        // The panel itself asks before replacing a file.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: f.url).write(to: url, options: .atomic) } catch { self.error = "Экспорт: \(error.localizedDescription)" }
    }
}

struct WorkflowProblems: View {
    let problems: [Workflow.Problem]

    var body: some View {
        ForEach(problems, id: \.self) { p in
            Label(p.message, systemImage: p.isError ? "xmark.octagon.fill" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(p.isError ? .red : .orange)
                .textSelection(.enabled)
        }
    }
}
