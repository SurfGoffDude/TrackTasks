import SwiftUI
import TrackTasksCore

/// Settings → «Агенты»: profiles a task can name in `agent:`.
struct AgentProfilesSection: View {
    @State private var profiles = AgentProfileStore.current
    @State private var name = ""
    @State private var model = ""
    @State private var agent = AgentID.claude
    @State private var error = ""
    @AppStorage(CodexLocator.key) private var codexPath = ""
    @State private var codexState = ""
    @State private var check: CodexProcess?
    @State private var server = RemoteServer(host: "")
    @State private var serverState: [String: String] = [:]
    @State private var acpCommand = ""
    @State private var acpArgs = ""
    @State private var acpChecks: [String: ACPProcess] = [:]
    private var remote: RemoteStatus { .shared }

    private var agents: [any Agent] { AgentRegistry.standard.all }

    var body: some View {
        Section("Агенты") {
            Picker("Профиль по умолчанию", selection: $profiles.defaultID) {
                ForEach(profiles.all.filter(\.canBeDefault)) { Text($0.title).tag($0.id) }
            }
            ForEach(profiles.custom) { p in
                HStack {
                    Text(p.id).monospaced()
                    Text("\(AgentRegistry.standard[p.agent]?.title ?? p.agent.rawValue) · \(p.model.isEmpty ? "модель по умолчанию" : p.model)")
                        .foregroundStyle(.secondary)
                    if let s = p.server { Text(s.title).font(.caption).foregroundStyle(.secondary) }
                    if let c = p.acp { Text(c.title).font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1).help(c.title) }
                    Spacer()
                    if let c = p.acp {
                        Button("Проверить") { checkACP(p.id, c) }.disabled(acpChecks[p.id] != nil)
                            .help("Запускает программу и спрашивает версию и возможности. Токены не тратятся")
                    }
                    if let s = p.server {
                        Button("Проверить") { checkServer(p.id, s) }.disabled(serverState[p.id] == Self.checking)
                            .help("Ключ сервера, git и claude. Токены не тратятся")
                    }
                    Button { profiles.remove(p.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Удалить профиль")
                }
                if let t = serverState[p.id] { Text(t).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            HStack {
                TextField("Имя", text: $name, prompt: Text("claude-opus"))
                if agents.count > 1 {
                    Picker("Агент", selection: $agent) {
                        ForEach(agents, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                }
                TextField("Модель", text: $model, prompt: Text("авто"))
                Button("Добавить", action: add).disabled(name.isEmpty)
            }
            if agent == .ssh { serverFields }
            if agent == .acp { acpFields }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Задача выбирает профиль полем agent: (или в карточке). Профиль задаёт агента и модель, прав не добавляет. Задача с удалённым профилем не запустится.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Путь к codex (пусто = авто)", text: $codexPath)
            HStack {
                Text(codexState.isEmpty ? "Найден: \(CodexLocator.resolve() ?? "—")" : codexState)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Проверить Codex", action: checkCodex).disabled(check != nil)
            }
            .onChange(of: codexPath) { codexState = "" }
        }
        .onChange(of: profiles) { _, p in AgentProfileStore.current = p }
        if !remote.leftovers.isEmpty || remote.pending > 0 { leftoversSection }
    }

    private static let checking = "Проверяю…"

    @ViewBuilder private var serverFields: some View {
        TextField("Сервер", text: $server.host, prompt: Text("адрес или имя из ~/.ssh/config"))
        HStack {
            TextField("Пользователь", text: $server.user, prompt: Text("из ssh config"))
            TextField("Порт", value: $server.port, format: .number.grouping(.never), prompt: Text("0 = из ssh config"))
        }
        TextField("Папка на сервере", text: $server.folder)
        TextField("claude на сервере", text: $server.claude)
        Text("Исходники проекта вместе с историей git, файл задачи, about.md и spectrack.md отправляются на этот сервер. Файлы .env и связанные папки (node_modules, vendor…) не отправляются. Ключ сервера должен быть в known_hosts: неизвестный или изменившийся блокирует запуск. Вход — только по ключу.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var acpFields: some View {
        TextField("Команда", text: $acpCommand, prompt: Text("имя программы или полный путь"))
        TextField("Аргументы", text: $acpArgs, prompt: Text("по одному на строке"), axis: .vertical)
            .lineLimit(1...6)
            .autocorrectionDisabled()
        Text("Любой установленный CLI с протоколом ACP v\(ACPSession.protocolVersion). Работает только в worktree и не бывает профилем по умолчанию. Это не песочница: запросы файлов ограничены папкой задачи, а свои инструменты и команды агент может выполнять где угодно.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// `initialize` only.
    private func checkACP(_ id: String, _ c: ACPCommand) {
        let p = ACPProcess()
        p.onExit = { r in
            serverState[id] = r.resultText.isEmpty ? r.errorText : r.resultText
            acpChecks[id] = nil
        }
        serverState[id] = Self.checking
        do { try p.check(c); acpChecks[id] = p } catch { serverState[id] = error.localizedDescription }
    }

    @ViewBuilder private var leftoversSection: some View {
        Section("На серверах") {
            if remote.pending > 0 {
                Text("Не завершено остановок и удалений на серверах: \(remote.pending). Повторяю, пока не получится.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(remote.leftovers) { w in
                HStack {
                    Text(w.server.title)
                    Text((w.folder as NSString).lastPathComponent + (w.orphan ? " · локальный worktree удалён" : "")).foregroundStyle(.secondary)
                    Spacer()
                    // While its worktree is here the run is continued from the queue.
                    if w.orphan { Button("Удалить с сервера", role: .destructive) { RemoteCleanup.shared.discard(w) } }
                }
                .help("Результат запуска не забран")
            }
        }
    }

    private func checkServer(_ id: String, _ s: RemoteServer) {
        serverState[id] = Self.checking
        Task {
            let text = await Task.detached { SSHAgent.check(s) }.value
            serverState[id] = text
        }
    }

    /// Version and login; no tokens are spent.
    private func checkCodex() {
        let p = CodexProcess()
        p.onExit = { r in
            codexState = r.resultText.isEmpty ? r.errorText : r.resultText
            check = nil
        }
        codexState = "Проверяю…"
        do { try p.start(nil, executable: nil); check = p } catch { codexState = error.localizedDescription }
    }

    private func add() {
        let id = name.trimmingCharacters(in: .whitespaces)
        let acp = ACPCommand(command: acpCommand.trimmingCharacters(in: .whitespaces),
                             args: acpArgs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        error = profiles.add(AgentProfile(id: id, title: id, agent: agent, model: model.trimmingCharacters(in: .whitespaces),
                                          server: agent == .ssh ? server : nil, acp: agent == .acp ? acp : nil)) ?? ""
        if error.isEmpty { name = ""; model = ""; acpCommand = ""; acpArgs = "" }
    }
}
