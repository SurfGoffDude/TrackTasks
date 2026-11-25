import SwiftUI
import TrackTasksCore

/// Files offered for `@` in the chat. Reads the disk: off the main thread.
enum ChatFiles {
    static let skipped: Set<String> = [".git", "node_modules", ".build", ".venv", "venv", "dist", "build", "target", "DerivedData", "Pods"]

    static func list(_ cwd: URL, limit: Int = 8000) -> [String] {
        let out = Worktrees.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: cwd)
        let git = out.ok ? out.out.split(separator: "\0").map(String.init) : []
        return git.isEmpty ? walk(cwd, limit: limit) : git
    }

    /// Level by level, so that with a limit every project of the folder still gets some.
    static func walk(_ root: URL, limit: Int, depth: Int = 6) -> [String] {
        var files: [String] = [], level = [""], seen = 0
        for _ in 0..<depth where !level.isEmpty {
            var next: [String] = []
            for dir in level {
                let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
                for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    seen += 1
                    if files.count >= limit || seen > limit * 5 { return files }
                    let name = u.lastPathComponent, path = dir.isEmpty ? name : dir + "/" + name
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if v?.isSymbolicLink == true { continue }
                    if v?.isDirectory == true {
                        if !skipped.contains(name) { next.append(path) }
                    } else {
                        files.append(path)
                    }
                }
            }
            level = next
        }
        return files
    }
}

/// Answer of `/tasks`.
enum ChatTasks {
    static let limit = 60

    static func markdown(_ projects: [(name: String?, tasks: [TaskItem])]) -> String {
        var open: [(name: String?, task: TaskItem)] = []
        for p in projects {
            for t in p.tasks where t.status != .done { open.append((p.name, t)) }
        }
        func order(_ t: TaskItem) -> Int { (t.status == .doing ? 10 : 0) + t.priority.rank }
        open.sort { order($0.task) > order($1.task) }
        guard !open.isEmpty else { return "Открытых задач нет." }
        var lines: [String] = open.prefix(limit).map { name, t in
            let project = name.map { "**" + $0 + "** · " } ?? ""
            return "- \(project)\(t.title) — \(t.status.title.lowercased()), \(t.priority.title.lowercased())"
        }
        if open.count > limit { lines.append("- …и ещё \(open.count - limit)") }
        return "Открытые задачи: \(open.count)\n\n" + lines.joined(separator: "\n")
    }
}

/// Field of the chat with everything above it: permissions, the «task or chat» card, the queue, suggestions.
struct ChatComposer: View {
    @Bindable var session: ClaudeSession
    let actions: [QuickAction]
    /// Open tasks for `/tasks`, as Markdown.
    let tasks: () -> String
    @FocusState private var focused: Bool
    @AppStorage(ClaudeModel.storageKey) private var model: ClaudeModel = .auto
    @State private var files: [String] = []
    @State private var filesRead = Date.distantPast
    @State private var found: [String] = []
    @State private var selection = 0
    /// Text for which the user closed the suggestions.
    @State private var dismissed: String?

    private struct Suggestion: Identifiable {
        var title: String
        var hint: String
        /// Text of the field once chosen.
        var text: String
        var runs: Bool
        var id: String { title }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(session.permissions) { r in
                PermissionCard(request: r) { allow, always in
                    session.answer(r, allow: allow, always: always)
                }
            }
            if let p = session.pending {
                pendingCard(p)
            }
            if !session.queue.isEmpty { queue }
            if !session.messages.isEmpty { quickActions }
            if session.editing != nil { editingBar }
            let list = suggestions
            if !list.isEmpty { suggestionList(list) }
            field
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: session.input) { selection = 0 }
        .onChange(of: session.editing) { if session.editing != nil { focused = true } }
        .task(id: query) { await findFiles() }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(actions) { a in
                    Button(a.title, action: a.run)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(session.isRunning)
                }
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Напиши… @ — файл, / — команда", text: $session.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.tab) { complete() }
                .onKeyPress(.escape) { closeSuggestions() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            Button(action: send) {
                Image(systemName: session.isRunning ? "text.line.last.and.arrowtriangle.forward" : "arrow.up")
                    .font(.body.weight(.bold))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(session.isRunning ? "В очередь: отправится после ответа" : "Отправить")
            .disabled(session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.pending != nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: Suggestions

    private var query: String? { ChatInput.fileToken(session.input)?.query }

    private var commands: [ChatInput.Command] {
        [.init("new", "Новый диалог"),
         .init("model", "Модель", values: ClaudeModel.allCases.map(\.rawValue)),
         .init("stop", "Остановить ответ"),
         .init("tasks", "Открытые задачи"),
         .init("help", "Что умеет чат")]
            + actions.map { .init(ChatInput.slug($0.title), $0.title) }
    }

    private var suggestions: [Suggestion] {
        let text = session.input
        guard focused, dismissed != text else { return [] }
        if let t = ChatInput.fileToken(text) {
            return found.map { Suggestion(title: $0, hint: "", text: ChatInput.insert($0, in: text, at: t), runs: false) }
        }
        return ChatInput.completions(text, commands: commands)
            .map { Suggestion(title: $0.text, hint: $0.hint, text: $0.text, runs: $0.runs) }
    }

    private func findFiles() async {
        guard let q = query else { found = []; return }
        if Date().timeIntervalSince(filesRead) > 30 {
            let cwd = session.cwd
            let list = await Task.detached(priority: .userInitiated) { ChatFiles.list(cwd) }.value
            guard !Task.isCancelled || files.isEmpty else { return }
            files = list
            filesRead = Date()
        }
        let all = files
        let best = await Task.detached(priority: .userInitiated) { ChatInput.rank(all, query: q) }.value
        guard !Task.isCancelled else { return }
        found = best
        selection = 0
    }

    private func suggestionList(_ list: [Suggestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                Button { choose(s, run: true) } label: {
                    HStack(spacing: 8) {
                        Text(s.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(s.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(i == selection ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func move(_ d: Int) -> KeyPress.Result {
        let n = suggestions.count
        guard n > 0 else { return .ignored }
        selection = (min(selection, n - 1) + d + n) % n
        return .handled
    }

    private var chosen: Suggestion? {
        let list = suggestions
        return list.isEmpty ? nil : list[min(selection, list.count - 1)]
    }

    private func complete() -> KeyPress.Result {
        guard let s = chosen else { return .ignored }
        choose(s, run: false)
        return .handled
    }

    private func closeSuggestions() -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        dismissed = session.input
        return .handled
    }

    private func choose(_ s: Suggestion, run: Bool) {
        session.input = s.text
        if run, s.runs { send() } else { focused = true }
    }

    /// Enter: the open suggestion first.
    private func submit() {
        guard let s = chosen else { return send() }
        // The file is already typed in full: nothing to choose.
        if let q = query, q == s.title { return send() }
        choose(s, run: true)
    }

    // MARK: Sending

    private func send() {
        let text = session.input
        if let (c, argument) = ChatInput.parse(text, commands: commands) {
            if run(c, argument) { session.input = "" }
            return
        }
        guard session.pending == nil else { return }
        session.input = ""
        session.submit(text, model: model)
    }

    /// Local commands never reach claude. false: the text stays in the field.
    private func run(_ c: ChatInput.Command, _ argument: String) -> Bool {
        if c.values.isEmpty, !argument.isEmpty {
            session.note("У команды `/\(c.name)` нет параметров.")
            return false
        }
        switch c.name {
        case "new":
            // Unsent texts come back to the field, the command itself doesn't.
            session.input = ""
            session.reset()
            return false
        case "stop": session.stop()
        case "tasks": session.note(tasks())
        case "help": session.note(help)
        case "model":
            if argument.isEmpty {
                session.note("Модель: \(model.title). Доступны: " + ClaudeModel.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", "))
            } else if let m = ClaudeModel(rawValue: argument.lowercased()) {
                model = m
                session.note("Модель: \(m.title) — со следующего сообщения")
            } else {
                session.note("Нет модели «\(argument)». Доступны: " + ClaudeModel.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", "))
                return false
            }
        default:
            guard !session.isRunning else {
                session.note("Дождись ответа: быстрые действия в очередь не ставятся.")
                return false
            }
            actions.first { ChatInput.slug($0.title) == c.name }?.run()
        }
        return true
    }

    private var help: String {
        commands.map { "- `/\($0.name)` — \($0.hint)" }.joined(separator: "\n")
            + "\n\n`@` — вставить путь к файлу. Enter во время ответа ставит сообщение в очередь. Остальные команды с `/` уходят в Claude Code."
    }

    // MARK: Cards

    private var editingBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
            Text("Изменение последнего запроса").lineLimit(1)
            Spacer(minLength: 4)
            Button("Отмена") { session.cancelEditing() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("В очереди: \(session.queue.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                Spacer(minLength: 4)
                if !session.isRunning, session.pending == nil {
                    Button("Отправить") { session.sendQueued() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(session.queue) { q in
                HStack(spacing: 6) {
                    Text(q.text).font(.callout).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.unqueue(q.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Убрать из очереди")
                }
            }
        }
        .padding(8)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
    }

    private func pendingCard(_ p: ClaudeSession.PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Завести задачу или сделать в чате?", systemImage: "questionmark.bubble.fill")
                .font(.callout.weight(.semibold))
            Text(p.text)
                .font(.callout)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
            Text("Задача попадёт в tasks/, её выполнит очередь. В чате Claude пишет только в tasks/, about.md и spectrack.md — код он здесь не правит.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Завести задачу") { session.confirmTask() }
                    .buttonStyle(.glassProminent)
                Button("Сделать в чате") { session.confirmChat() }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Button("Отмена") { session.cancelPending() }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
