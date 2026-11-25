import Foundation
import SwiftUI
import TrackTasksCore

/// Interactive chat with resumable session. Every conversation is saved to ChatHistory.
@Observable @MainActor
final class ClaudeSession {
    enum Role: String, Codable { case user, assistant, tool, error, info }

    /// State of Claude's session before a request: a repeated request starts here.
    struct Base: Codable, Equatable {
        /// nil: the request begins the conversation.
        var session: String?
        var point: String?
    }

    /// New fields are optional: chats saved without them must decode.
    struct Message: Identifiable, Equatable, Codable {
        var id = UUID()
        let role: Role
        var text: String
        var tool: ChatToolCall? = nil
        /// What was sent, when it differs from the shown text.
        var prompt: String? = nil
        var model: String? = nil
        var base: Base? = nil
        /// Answer of a local command, shown as Markdown.
        var local: Bool? = nil
    }

    let cwd: URL
    let title: String
    let systemPrompt: String
    var messages: [Message] = []
    var isRunning = false
    var sessionID: String?
    var totalCost: Double = 0
    var context: ClaudeContext?
    /// Saved chats for this folder, newest first.
    var history: [ChatRecord] = []
    /// Tool uses waiting for the user's approval.
    var permissions: [PermissionRequest] = []
    var chatID = UUID()
    private var chatCreated = Date()
    private var point: String?
    private var branch: Base?
    /// Text of the input field.
    var input = ""
    /// Запрос, который сейчас правят: отправка начнёт с него новую ветку.
    private(set) var editing: UUID?
    /// What was in the field before that.
    @ObservationIgnored private var draft = ""
    /// Просьба выполнить работу, ждущая выбора: завести задачу или сделать в чате.
    var pending: PendingRequest?

    struct PendingRequest: Equatable {
        let text: String
        let model: ClaudeModel
        var replacing: UUID? = nil
    }

    /// Messages written while Claude answers.
    private(set) var queue: [Queued] = []

    struct Queued: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let model: ClaudeModel
    }

    /// UserDefaults: спрашивать ли про задачу (по умолчанию да).
    nonisolated static let askKey = "chatAskTaskOrChat"
    static var asksBeforeTask: Bool {
        UserDefaults.standard.object(forKey: askKey) as? Bool ?? true
    }

    @ObservationIgnored var onFinish: (() -> Void)?
    /// Runs before each request; a returned note is shown in the chat (e.g. «добавлен git»).
    @ObservationIgnored var beforeSend: (() -> String?)?
    @ObservationIgnored private var proc: ClaudeProcess?
    @ObservationIgnored private var stopAsked = false
    /// Stopped runs of chats already left: kept until they exit, for their cost and session.
    private var closing: [ClaudeProcess] = []

    // Stand-ins in tests.
    @ObservationIgnored private let historyRoot: URL
    @ObservationIgnored private let executable: String?
    @ObservationIgnored private let makeProcess: @MainActor () -> ClaudeProcess

    init(cwd: URL, title: String, systemPrompt: String, historyRoot: URL = ChatHistory.root,
         executable: String? = nil, makeProcess: @escaping @MainActor () -> ClaudeProcess = { ClaudeProcess() }) {
        self.cwd = cwd
        self.title = title
        self.systemPrompt = systemPrompt
        self.historyRoot = historyRoot
        self.executable = executable
        self.makeProcess = makeProcess
        history = ChatHistory.prune(ChatHistory.list(cwd: cwd, in: historyRoot), cwd: cwd, in: historyRoot)
        // Pick up where we left off.
        if let last = history.first { load(last) }
    }

    /// A restart of the app would lose something.
    var isBusy: Bool { isRunning || !closing.isEmpty || !queue.isEmpty }

    var chatTitle: String {
        let first = messages.first { $0.role == .user }?.text ?? ""
        let line = first.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 70 ? String(t.prefix(70)) + "…" : (t.isEmpty ? "Без названия" : t)
    }

    // MARK: Conversations

    /// Start a fresh conversation; the current one stays in history.
    func reset() {
        leave()
        clear()
    }

    func open(_ r: ChatRecord) {
        guard !isRunning, r.id != chatID else { return }
        leave()
        load(r)
    }

    func deleteChat(_ id: UUID) {
        ChatHistory.delete(id, cwd: cwd, in: historyRoot)
        history.removeAll { $0.id == id }
        if id == chatID {
            leave(save: false)
            clear()
        }
    }

    /// Stops the run and returns unsent texts to the field; the chat stays in history.
    private func leave(save: Bool = true) {
        var unsent = queue.map(\.text)
        if let p = pending { unsent.insert(p.text, at: 0) }
        queue = []
        pending = nil
        endEditing()
        returnToInput(unsent)
        if let p = proc {
            closing.append(p)
            proc = nil
            isRunning = false
            permissions = []
            p.stop()
            interruptTools()
            messages.append(Message(role: .info, text: "Остановлено"))
        }
        if save { persist() }
    }

    private func clear() {
        messages = []
        sessionID = nil
        totalCost = 0
        context = nil
        point = nil
        branch = nil
        chatID = UUID()
        chatCreated = Date()
    }

    private func load(_ r: ChatRecord) {
        chatID = r.id
        chatCreated = r.created
        messages = r.messages
        sessionID = r.sessionID
        totalCost = r.totalCost
        point = r.point
        branch = r.branch
        context = nil
        interruptTools()
    }

    private func persist() {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let r = ChatRecord(id: chatID, title: chatTitle, created: chatCreated, updated: Date(),
                           sessionID: sessionID, totalCost: totalCost, messages: Self.trimmed(messages),
                           point: point, branch: branch)
        ChatHistory.save(r, cwd: cwd, in: historyRoot)
        history.removeAll { $0.id == r.id }
        history.insert(r, at: 0)
    }

    /// Results of the oldest calls go first.
    static func trimmed(_ messages: [Message], limit: Int = ChatToolCall.savedLimit) -> [Message] {
        var out = messages, left = limit
        for i in out.indices.reversed() {
            guard let n = out[i].tool?.result?.count else { continue }
            left -= n
            if left < 0 { out[i].tool?.result = "Результат не сохранён: слишком длинный диалог" }
        }
        return out
    }

    private func interruptTools() {
        for i in messages.indices where messages[i].tool?.state == .running { messages[i].tool?.state = .interrupted }
    }

    private func returnToInput(_ texts: [String]) {
        let all = texts + (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [input])
        if !texts.isEmpty { input = all.joined(separator: "\n") }
    }

    /// Answer of a local command: Claude doesn't see it.
    func note(_ markdown: String) {
        messages.append(Message(role: .info, text: markdown, local: true))
    }

    func stop() {
        guard let proc else { return }
        stopAsked = true
        proc.stop()
    }

    // MARK: Sending

    /// Ввод из поля чата: просьбу выполнить держит до выбора, остальное уходит сразу. Пока Claude отвечает — в очередь.
    /// Быстрые действия зовут `send` напрямую и плашку не вызывают.
    func submit(_ prompt: String, model: ClaudeModel = .current) {
        guard pending == nil else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isRunning {
            queue.append(Queued(text: text, model: model))
        } else {
            let replacing = editing
            endEditing()
            deliver(PendingRequest(text: text, model: model, replacing: replacing))
        }
    }

    private func deliver(_ r: PendingRequest) {
        if Self.asksBeforeTask, ChatIntent.isRequest(r.text) {
            pending = r
        } else {
            send(r.text, model: r.model, replacing: r.replacing)
        }
    }

    /// «Сделать в чате»: прежняя отправка.
    func confirmChat() {
        guard let p = pending else { return }
        pending = nil
        send(p.text, model: p.model, replacing: p.replacing)
    }

    /// «Завести задачу»: Claude оформляет задачу в tasks/ и ничего не выполняет.
    func confirmTask() {
        guard let p = pending else { return }
        pending = nil
        send(ClaudePrompts.asTask(p.text), display: p.text, model: p.model, replacing: p.replacing)
    }

    /// Отмена: текст возвращается в поле, чтобы его можно было поправить.
    func cancelPending() {
        guard let p = pending else { return }
        pending = nil
        editing = p.replacing
        returnToInput([p.text])
    }

    func unqueue(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// The next queued message; after a stop or an error the user asks for it.
    func sendQueued() {
        guard !isRunning, pending == nil, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        deliver(PendingRequest(text: q.text, model: q.model))
    }

    // MARK: The last request again

    /// «Повторить» and «Изменить» are offered for it.
    var lastRequest: Message? {
        isRunning || pending != nil ? nil : messages.last { $0.role == .user }
    }

    func repeatLast() {
        guard let m = lastRequest else { return }
        cancelEditing()
        let model = m.model.flatMap(ClaudeModel.init(rawValue:)) ?? .current
        send(m.prompt ?? m.text, display: m.text, model: model, replacing: m.id)
    }

    /// The shown text is edited; a quick action shows its label, so there the request itself.
    func editLast() {
        guard let m = lastRequest, editing == nil else { return }
        let asTask = m.prompt == ClaudePrompts.asTask(m.text)
        draft = input
        input = asTask ? m.text : m.prompt ?? m.text
        editing = m.id
    }

    func cancelEditing() {
        guard editing != nil else { return }
        input = ""
        endEditing()
    }

    private func endEditing() {
        editing = nil
        let d = draft
        draft = ""
        if !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { returnToInput([d]) }
    }

    /// New chat with everything before the request; the old chat stays in history. false: Claude's session at that
    /// moment is unknown (an old chat), the request just goes on as a new message.
    private func startBranch(at id: UUID) -> Bool {
        guard let m = lastRequest, m.id == id, let base = m.base,
              let i = messages.firstIndex(where: { $0.id == id }) else { return false }
        persist()
        let kept = Array(messages[..<i])
        clear()
        messages = kept
        sessionID = base.session
        point = base.point
        branch = base.session == nil ? nil : base
        return true
    }

    private var base: Base? {
        if let branch { return branch }
        guard let sessionID else { return Base() }
        return point.map { Base(session: sessionID, point: $0) }
    }

    /// `model`: planning actions pass `.planning`; free chat stays on `.current`.
    /// `replacing`: the last request, asked again from its place in the conversation.
    func send(_ prompt: String, display: String? = nil, model: ClaudeModel = .current, replacing: UUID? = nil) {
        guard !isRunning else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        endEditing()
        if let replacing { _ = startBranch(at: replacing) }
        let shown = display ?? text
        messages.append(Message(role: .user, text: shown, prompt: shown == text ? nil : text, model: model.rawValue, base: base))
        if let note = beforeSend?() { messages.append(Message(role: .info, text: note)) }

        let p = makeProcess(), chat = chatID
        // A run of a chat already left must not write to the new one.
        weak var weakP = p
        p.onEvent = { [weak self] e in
            // Tools come from `onTool`.
            if case .text(let t) = e { self?.live(weakP)?.messages.append(Message(role: .assistant, text: t)) }
        }
        p.onTool = { [weak self] in self?.live(weakP)?.show($0) }
        p.onContext = { [weak self] in self?.live(weakP)?.context = $0 }
        p.onExit = { [weak self] s in
            guard let self, let p = weakP else { return }
            if proc === p { finished(s, point: p.point) } else { closed(p, s, chat: chat) }
        }
        p.onPermission = { [weak self] r in
            guard let s = self?.live(weakP) else { return }
            s.permissions.append(r)
            Attention.request()
        }
        do {
            try p.start(ClaudeOptions(cwd: cwd, prompt: text, systemPrompt: systemPrompt, model: model.alias,
                                      resume: branch?.session ?? sessionID, fork: branch != nil, resumeAt: branch?.point,
                                      allowedTools: ClaudeTools.planning, fromChat: true), executable: executable)
            proc = p
            stopAsked = false
            isRunning = true
        } catch {
            messages.append(Message(role: .error, text: error.localizedDescription))
        }
        persist()
    }

    private func live(_ p: ClaudeProcess?) -> ClaudeSession? {
        p != nil && proc === p ? self : nil
    }

    private func show(_ e: ClaudeToolEvent) {
        switch e {
        case .started(let call, let title):
            messages.append(Message(role: .tool, text: title, tool: call))
        case .finished(let id, let result, let failed):
            guard let i = messages.lastIndex(where: { $0.tool?.id == id }) else { return }
            messages[i].tool?.result = result
            messages[i].tool?.state = failed ? .failed : .done
        }
    }

    func answer(_ r: PermissionRequest, allow: Bool, always: Bool = false) {
        proc?.respond(r, allow: allow, always: always)
        permissions.removeAll { $0.id == r.id }
        messages.append(Message(role: .tool, text: (allow ? (always ? "Разрешено всегда: " : "Разрешено: ") : "Отклонено: ") + r.title))
    }

    private func finished(_ s: ClaudeRunStats, point p: String?) {
        permissions = []
        isRunning = false
        proc = nil
        interruptTools()
        (sessionID, point, branch) = adopted(s, p, session: sessionID, point: point, branch: branch)
        let stopped = s.stopped || stopAsked
        if stopped {
            messages.append(Message(role: .info, text: "Остановлено"))
        } else if s.failed {
            messages.append(Message(role: .error, text: s.errorText))
            if s.errorText.localizedCaseInsensitiveContains("no conversation found") {
                // Claude's own session file is gone: continue without the old context.
                sessionID = nil
                point = nil
                branch = nil
                messages.append(Message(role: .info, text: "Старая сессия Claude недоступна — следующее сообщение начнёт новый контекст"))
            }
        }
        totalCost += s.costUSD ?? 0
        Spend.shared.add(s, project: title, kind: "Чат")
        if !s.summary.isEmpty { messages.append(Message(role: .info, text: s.summary)) }
        persist()
        onFinish?()
        if !stopped, !s.failed, s.gotResult { sendQueued() }
    }

    /// A run stopped by leaving its chat: the saved chat gets its session and cost.
    private func closed(_ p: ClaudeProcess, _ s: ClaudeRunStats, chat: UUID) {
        closing.removeAll { $0 === p }
        Spend.shared.add(s, project: title, kind: "Чат")
        if chat == chatID {
            // Opened again meanwhile.
            if !isRunning { (sessionID, point, branch) = adopted(s, p.point, session: sessionID, point: point, branch: branch) }
            totalCost += s.costUSD ?? 0
            persist()
        } else if let i = history.firstIndex(where: { $0.id == chat }) {
            var r = history[i]
            (r.sessionID, r.point, r.branch) = adopted(s, p.point, session: r.sessionID, point: r.point, branch: r.branch)
            r.totalCost += s.costUSD ?? 0
            history[i] = r
            ChatHistory.save(r, cwd: cwd, in: historyRoot)
        }
        onFinish?()
    }

    /// Session, point and branch after a run. Until the branch has its own session the next request must start
    /// from the same place.
    private func adopted(_ s: ClaudeRunStats, _ p: String?, session: String?, point: String?,
                         branch: Base?) -> (session: String?, point: String?, branch: Base?) {
        (s.sessionID ?? session, p ?? point, s.sessionID == nil || s.sessionID == branch?.session ? branch : nil)
    }
}
