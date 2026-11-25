import SwiftUI

/// A project document that can be edited as raw Markdown.
struct ProjectDoc: Identifiable {
    let title: String
    let url: URL
    /// Initial text when the file doesn't exist yet.
    var template = ""
    var id: String { url.path }
}

/// spectrack.md: idea, goals, decisions, agents' findings. Read by every agent before work.
struct SpecCard: View {
    @Environment(Store.self) private var store
    let project: Project
    let edit: (ProjectDoc) -> Void
    @State private var expanded = false

    var body: some View {
        let findings = expanded ? 0 : SpecDoc.findings(in: project.spec).count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Спецификация", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                if findings > 0 {
                    Text("находок: \(findings)").font(.caption).foregroundStyle(.secondary)
                        .help("Записано агентами в «Находки»")
                }
            }
            if project.hasSpec {
                if expanded { MarkdownView(text: project.spec, hideH1: true) }
            } else {
                Text("Идея, цели и решения проекта. Агенты читают spectrack.md перед работой и дополняют находками.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8) {
                if project.hasSpec {
                    Button(expanded ? "Свернуть" : "Показать") { withAnimation(.snappy) { expanded.toggle() } }
                    Button("Открыть \(project.specURL.lastPathComponent)") { store.open(project.specURL) }
                }
                Button {
                    edit(ProjectDoc(title: project.specURL.lastPathComponent, url: project.specURL,
                                    template: SpecDoc.template(name: project.displayName, idea: project.summary)))
                } label: { Label(project.hasSpec ? "Править" : "Создать", systemImage: "pencil") }
                Button {
                    store.askClaude(project, prompt: ClaudePrompts.spec, label: project.hasSpec ? "Обнови spectrack.md" : "Создай spectrack.md",
                                    model: .planning)
                } label: { Label(project.hasSpec ? "Обновить с Claude" : "Сгенерировать с Claude", systemImage: "sparkles") }
            }
            .buttonStyle(.glass)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Raw Markdown editor with preview. Never silently overwrites changes made on disk meanwhile.
struct ProjectDocEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let doc: ProjectDoc
    let projectID: String
    @State private var text = ""
    /// Contents on disk when loaded; nil = no file.
    @State private var original: String?
    @State private var loaded = false
    @State private var preview = false
    @State private var error: String?
    @State private var conflict = false
    @State private var confirmDiscard = false

    private var initial: String { original ?? doc.template }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(doc.title).font(.title2.weight(.semibold))
                Spacer()
                Button { preview.toggle() } label: {
                    Label(preview ? "Править" : "Просмотр", systemImage: preview ? "pencil" : "eye")
                }
                .buttonStyle(.glass)
                .keyboardShortcut("e", modifiers: .command)
                .help("⌘E — переключить просмотр и правку")
            }
            Group {
                if preview {
                    ScrollView { MarkdownView(text: Frontmatter.parse(text).body, roomy: true).padding(14) }
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .disabled(!loaded)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Отмена") { if loaded, text != initial { confirmDiscard = true } else { dismiss() } }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { save(force: false) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!loaded)
            }
        }
        .padding(24)
        .frame(width: 820, height: 700)
        .interactiveDismissDisabled(loaded && text != initial)
        .onAppear { if !loaded { load() } }
        .alert("Файл изменился на диске", isPresented: $conflict) {
            Button("Перезаписать моим текстом", role: .destructive) { save(force: true) }
            Button("Загрузить с диска", role: .destructive) { load() }
            Button("Вернуться к правке", role: .cancel) {}
        } message: {
            Text("Пока ты правил, \(doc.title) изменил Claude или другой редактор.")
        }
        .confirmationDialog("Закрыть без сохранения?", isPresented: $confirmDiscard) {
            Button("Не сохранять", role: .destructive) { dismiss() }
            Button("Продолжить правку", role: .cancel) {}
        }
    }

    private func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: doc.url.path) else { return nil }
        return try String(contentsOf: doc.url, encoding: .utf8)
    }

    private func load() {
        do {
            original = try read()
            text = initial
            loaded = true
            error = nil
        } catch {
            loaded = false
            self.error = "Не удалось прочитать: \(error.localizedDescription)"
        }
    }

    private func save(force: Bool) {
        do {
            if !force, try read() != original { conflict = true; return }
            try text.write(to: doc.url, atomically: true, encoding: .utf8)
            store.reloadProject(projectID)
            dismiss()
        } catch {
            self.error = "Не сохранено: \(error.localizedDescription)"
        }
    }
}
