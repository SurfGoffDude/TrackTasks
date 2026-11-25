import SwiftUI
import TrackTasksCore

struct WorkflowDraft: Identifiable {
    let id = UUID()
    var name: String
    var text: String
    /// Existing file; nil = a new one.
    var url: URL?
    /// Text from outside: shown as a whole first, it goes into agents' prompts.
    var imported = false
}

/// Steps as a form, or the file as it is written.
struct WorkflowEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft: WorkflowDraft
    let project: Project
    @State private var name: String
    @State private var text: String
    @State private var workflow: Workflow
    @State private var budget: String
    @State private var asText: Bool
    @State private var error = ""
    @State private var replacing = false

    init(draft: WorkflowDraft, project: Project) {
        self.draft = draft
        self.project = project
        let w = Workflow.parse(draft.text)
        _name = State(initialValue: draft.name)
        _text = State(initialValue: draft.text)
        _workflow = State(initialValue: w?.workflow ?? Workflow())
        _budget = State(initialValue: w?.workflow.budget.map { String($0) } ?? "")
        // A form would drop values that can't be read.
        _asText = State(initialValue: draft.imported || w == nil || w!.problems.contains(where: \.isError))
    }

    /// What would be written.
    private var current: String {
        guard !asText else { return text }
        var w = workflow
        let b = budget.trimmingCharacters(in: .whitespaces)
        w.budget = b.isEmpty ? nil : Double(b.replacingOccurrences(of: ",", with: ".")) ?? -1
        return w.serialized(updating: text)
    }
    private var target: URL { draft.url ?? WorkflowFile.url(name, in: project.url) }
    private var problems: [Workflow.Problem] {
        guard let f = WorkflowFile(url: target, text: current) else { return [.init(error: "Нет шагов")] }
        return f.allProblems
    }

    var body: some View {
        let problems = problems
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if draft.url == nil {
                    TextField("Имя файла", text: $name).font(.body.monospaced()).frame(width: 180)
                } else {
                    Text(draft.name).font(.title3.monospaced())
                }
                Spacer()
                Picker("Вид", selection: Binding(get: { asText }, set: show)) {
                    Text("Шаги").tag(false)
                    Text("Файл").tag(true)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
            }
            if draft.imported {
                Text("Импортированный текст попадёт в промпты агентов. Прочитай его целиком перед сохранением.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if asText {
                TextEditor(text: $text).font(.body.monospaced()).scrollContentBackground(.hidden)
            } else {
                ScrollView { form }
            }
            WorkflowProblems(problems: problems)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Бюджет сверяется перед каждым шагом: один идущий шаг может его превысить.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Сохранить") { save(replace: false) }
                    .buttonStyle(.glassProminent)
                    .disabled(problems.contains(where: \.isError))
            }
        }
        .padding(24)
        .frame(width: 760, height: 680)
        .confirmationDialog("Файл \(target.lastPathComponent) уже есть. Заменить?", isPresented: $replacing) {
            Button("Заменить", role: .destructive) { save(replace: true) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Название", text: $workflow.title)
                TextField("Бюджет, $", text: $budget).frame(width: 110)
                    .help("На всю задачу. Codex стоимость не сообщает — её держат повторы")
            }
            ForEach(workflow.steps.indices, id: \.self) { stepForm($0) }
            Button("Добавить шаг") { workflow.steps.append(.init(title: "Шаг \(workflow.steps.count + 1)", type: .review)) }
                .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func stepForm(_ i: Int) -> some View {
        // A row being removed may be asked for its value once more.
        if workflow.steps.indices.contains(i) {
            let s = Binding(get: { workflow.steps.indices.contains(i) ? workflow.steps[i] : .init(title: "", type: .code) },
                            set: { if workflow.steps.indices.contains(i) { workflow.steps[i] = $0 } })
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Название шага", text: Binding(get: { s.wrappedValue.title }, set: { rename(i, to: $0) })).frame(width: 200)
                    Picker("", selection: s.type) { ForEach(Workflow.StepType.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().fixedSize()
                    Spacer()
                    Button { workflow.steps.swapAt(i, i - 1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                    Button { workflow.steps.swapAt(i, i + 1) } label: { Image(systemName: "arrow.down") }.disabled(i + 1 >= workflow.steps.count)
                    Button(role: .destructive) { workflow.steps.remove(at: i) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.glass).controlSize(.small)
                HStack {
                    let profiles = AgentProfileStore.current
                    Picker("Агент", selection: s.agent) {
                        Text("Как у задачи").tag("")
                        ForEach(profiles.all) { Text($0.title).tag($0.id) }
                        if !s.wrappedValue.agent.isEmpty, profiles.resolve(s.wrappedValue.agent) == nil {
                            Text("⚠︎ \(s.wrappedValue.agent) — нет такого").tag(s.wrappedValue.agent)
                        }
                    }
                    .fixedSize()
                    TextField("Модель (пусто — из профиля)", text: s.model)
                    Picker("Остановка", selection: s.stop) {
                        Text(s.wrappedValue.type == .plan ? "После (по умолчанию)" : "Нет (по умолчанию)").tag(Workflow.Stop?.none)
                        Text("Нет").tag(Workflow.Stop?.some(.none))
                        Text("До").tag(Workflow.Stop?.some(.before))
                        Text("После").tag(Workflow.Stop?.some(.after))
                    }
                    .fixedSize()
                }
                HStack {
                    transition("Дальше", s.next, empty: "Следующий по порядку", end: true)
                    if s.wrappedValue.type == .review || !s.wrappedValue.onIssues.isEmpty {
                        transition("Замечания", s.onIssues, empty: "Решаю я", end: false)
                    }
                    Picker("Повторы", selection: s.repeats) {
                        Text("—").tag(Int?.none)
                        ForEach(Workflow.repeatsRange, id: \.self) { Text("до \($0)").tag(Int?.some($0)) }
                    }
                    .fixedSize()
                    .help("Сколько раз шаг может выполниться")
                }
                TextField("Указания агенту для этого шага", text: s.text, axis: .vertical).lineLimit(1...6)
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        }
    }

    private func transition(_ title: String, _ value: Binding<String>, empty: String, end: Bool) -> some View {
        let titles = workflow.steps.map(\.title)
        return Picker(title, selection: value) {
            Text(empty).tag("")
            ForEach(Array(Set(titles)).sorted(), id: \.self) { Text($0).tag($0) }
            if end { Text("Конец").tag(Workflow.end) }
            if !value.wrappedValue.isEmpty, value.wrappedValue != Workflow.end, !titles.contains(value.wrappedValue) {
                Text(value.wrappedValue).tag(value.wrappedValue)
            }
        }
        .fixedSize()
    }

    /// Transitions follow the new title.
    private func rename(_ i: Int, to title: String) {
        guard workflow.steps.indices.contains(i) else { return }
        let old = workflow.steps[i].title
        workflow.steps[i].title = title
        guard !old.isEmpty, !title.isEmpty, !workflow.steps.contains(where: { $0.title == old }) else { return }
        for j in workflow.steps.indices {
            if workflow.steps[j].next == old { workflow.steps[j].next = title }
            if workflow.steps[j].onIssues == old { workflow.steps[j].onIssues = title }
        }
    }

    private func show(_ file: Bool) {
        error = ""
        if file {
            text = current
            asText = true
        } else if let p = Workflow.parse(text), !p.problems.contains(where: \.isError) {
            workflow = p.workflow
            budget = p.workflow.budget.map { String($0) } ?? ""
            asText = false
        } else {
            error = "Сначала исправь ошибки в файле — форма потеряла бы эти значения"
        }
    }

    private func save(replace: Bool) {
        let out = current, url = target, fm = FileManager.default
        if let old = draft.url {
            // Changed on disk meanwhile: never overwritten.
            guard (try? String(contentsOf: old, encoding: .utf8)) == draft.text else {
                error = "Файл изменился на диске — закрой окно и открой его заново"
                return
            }
        } else if fm.fileExists(atPath: url.path), !replace {
            replacing = true
            return
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: url, atomically: true, encoding: .utf8)
            store.reloadProject(project.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
