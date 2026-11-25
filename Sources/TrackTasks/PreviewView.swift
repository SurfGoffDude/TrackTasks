import SwiftUI
import TrackTasksCore

/// One server of a task; lives while the app does.
struct PreviewTarget: Codable, Hashable {
    var job: UUID
    var server: UUID
}

/// Page of the task's server: pick an element, write a comment, look at the message and send it to the task's session.
struct PreviewView: View {
    static let windowID = "preview"

    enum Device: String, CaseIterable, Identifiable {
        case window = "По окну", phone = "Телефон 390×844", tablet = "Планшет 820×1180", desktop = "Компьютер 1440×900"
        var id: String { rawValue }
        var size: CGSize? {
            switch self {
            case .window: nil
            case .phone: CGSize(width: 390, height: 844)
            case .tablet: CGSize(width: 820, height: 1180)
            case .desktop: CGSize(width: 1440, height: 900)
            }
        }
    }

    let target: PreviewTarget
    @Environment(Store.self) private var store
    @State private var page: PreviewPage?
    @State private var device = Device.window
    @State private var error = ""
    @State private var sending = false
    @State private var confirmRepeat = false
    @State private var attempt = 0

    private var job: Job? { store.jobs.job(target.job) }
    private var server: DevServer? { job.flatMap { DevServers.shared.servers(in: $0.runDir).first { $0.id == target.server } } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                bar
                Divider()
                if let u = page?.outside { outsideBar(u) }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 420)
            if let job { panel(job).frame(minWidth: 280, idealWidth: 340, maxWidth: 480) }
        }
        .navigationTitle(job.map { "Превью: \($0.title)" } ?? "Превью")
        .task(id: attempt) { await open() }
        .onChange(of: server?.isRunning) { _, on in if on != true { page?.close("Сервер остановлен") } }
        .onChange(of: server?.port) { page?.close("Сервер сменил порт — открой страницу заново") }
        .onDisappear {
            page?.close("Окно закрыто")
            store.jobs.previews.save(target.job)
        }
    }

    private func open() async {
        guard let job else { return }
        store.jobs.openPreviewDraft(job)
        page?.close("")
        page = nil
        guard let s = server, s.isRunning, let root = s.pty?.pid else { return }
        let port = s.port
        let more = DevServers.shared.servers(in: job.runDir).filter { $0.id != s.id && $0.isRunning }.compactMap { o in o.pty.map { (o.port, $0.pid) } }
        let others = await Task.detached { Set(more.filter { ProcessTree.listens(on: $0.0, root: $0.1) }.map(\.0)) }.value
        guard !Task.isCancelled else { return }
        let p = PreviewPage(policy: PreviewPolicy(port: port, others: others)) { [weak s] in
            guard let s, s.isRunning, s.port == port else { return false }
            let ours = await Task.detached(priority: .userInitiated) { ProcessTree.listens(on: port, root: root) }.value
            return ours && s.isRunning && s.port == port
        }
        page = p
        await p.open()
    }

    // MARK: Page

    private var bar: some View {
        HStack(spacing: 8) {
            Button { Task { await page?.reload() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(page?.phase != .open)
            Picker("Размер", selection: $device) { ForEach(Device.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().fixedSize()
            if let page, page.picking {
                Button("Отменить выбор") { page.cancelPick() }
            } else {
                Button { startPick() } label: { Label("Выбрать элемент", systemImage: "cursorarrow.rays") }
                    .disabled(page?.canPick != true || pickBlocked != nil)
                    .help(pickBlocked ?? "Щёлкни по элементу страницы; Esc — отмена")
            }
            Spacer()
            Text("Инспектор: меню правой кнопки").font(.caption).foregroundStyle(.secondary)
            if let u = server?.url, server?.isRunning == true { Button("Открыть в браузере") { NSWorkspace.shared.open(u) } }
        }
        .padding(8)
    }

    private var pickBlocked: String? {
        guard let job else { return "Задачи больше нет в очереди" }
        if job.worktree == nil { return store.jobs.previewBlocked(job) }
        return store.jobs.previews.draft(job.id)?.delivery?.state == .sending ? "Прошлый комментарий отправляется" : nil
    }

    private func outsideBar(_ u: URL) -> some View {
        HStack {
            Image(systemName: "arrow.up.right.square")
            Text("Страница открывает посторонний адрес: \(UntrustedText.line(u.absoluteString))").font(.caption).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button("Открыть снаружи") { NSWorkspace.shared.open(u); page?.outside = nil }
            Button("Не открывать") { page?.outside = nil }
        }
        .padding(8)
        .background(.yellow.opacity(0.15))
    }

    @ViewBuilder
    private var content: some View {
        if let page, case .open = page.phase, let web = page.web {
            VStack(spacing: 0) {
                if !page.note.isEmpty { Text(page.note).font(.caption).foregroundStyle(.orange).padding(4) }
                if let size = device.size {
                    ScrollView([.horizontal, .vertical]) {
                        PreviewWebView(web: web).frame(width: size.width, height: size.height).border(.separator).padding(12)
                    }
                } else { PreviewWebView(web: web) }
            }
        } else {
            VStack(spacing: 10) {
                if let page {
                    switch page.phase {
                    case .closed(let why): Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    default: ProgressView()
                    }
                } else { Text("Сервер не запущен").foregroundStyle(.secondary) }
                if server?.isRunning == true { Button("Повторить") { attempt += 1 } }
            }
            .padding(24)
        }
    }

    /// Makes a draft only.
    private func startPick() {
        guard let page, let job else { return }
        error = ""
        Task {
            guard let p = await page.pick(), pickBlocked == nil else { return }
            let comment = store.jobs.previews.draft(job.id)?.comment ?? ""
            do { try store.jobs.previews.put(PreviewDraft(element: p.element, comment: comment), shot: p.png, for: job.id) }
            catch { self.error = "Черновик не сохранён: \(error.localizedDescription)" }
        }
    }

    // MARK: Draft

    @ViewBuilder
    private func panel(_ job: Job) -> some View {
        let previews = store.jobs.previews
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Комментарий агенту").font(.headline)
                if let d = previews.draft(job.id) {
                    Text(d.element.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if let png = previews.shot(job.id), let image = NSImage(data: png) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 200).border(.separator)
                    } else { Text("Снимок потерян — выбери элемент заново").font(.caption).foregroundStyle(.red) }
                    TextEditor(text: Binding(get: { previews.draft(job.id)?.comment ?? "" }, set: { previews.setComment($0, for: job.id) }))
                        .font(.body).frame(minHeight: 90).border(.separator)
                        .disabled(d.delivery?.state == .sending || sending)
                        .task(id: d.comment) {
                            try? await Task.sleep(for: .milliseconds(700))
                            if !Task.isCancelled, previews.draft(job.id)?.id == d.id { previews.save(job.id) }
                        }
                    if let text = store.jobs.previewMessage(job, d) {
                        Text("Будет отправлено").font(.caption.weight(.medium))
                        Text(text).font(.caption2.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                        sendRow(job, d, text)
                    } else { Text(store.jobs.previewBlocked(job) ?? "").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(pickBlocked ?? "Нажми «Выбрать элемент» и щёлкни по странице. Отправка — только кнопкой после просмотра.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sendRow(_ job: Job, _ d: PreviewDraft, _ text: String) -> some View {
        let blocked = store.jobs.previewBlocked(job)
        switch d.delivery?.state {
        case .sending: Text("Отправляется — удалится, когда агент начнёт ход").font(.caption).foregroundStyle(.secondary)
        case .unclear: Text("Возможно, уже отправлен: проверь ответ агента").font(.caption).foregroundStyle(.orange)
        case .failed: Text("Не отправлен").font(.caption).foregroundStyle(.red)
        case nil: EmptyView()
        }
        if let blocked { Text(blocked).font(.caption).foregroundStyle(.secondary) }
        HStack {
            Button("Удалить черновик", role: .destructive) { store.jobs.previews.remove(job.id) }
                .disabled(d.delivery?.state == .sending || sending)
            Spacer()
            Button("Отправить агенту") { if d.delivery?.state == .unclear { confirmRepeat = true } else { send(job, text) } }
                .buttonStyle(.borderedProminent)
                .disabled(blocked != nil || d.isBlank || sending || d.delivery?.state == .sending)
        }
        .confirmationDialog("Комментарий мог уже уйти. Отправить ещё раз?", isPresented: $confirmRepeat) {
            Button("Отправить ещё раз") { send(job, text) }
        }
    }

    private func send(_ job: Job, _ text: String) {
        sending = true
        error = ""
        Task {
            error = await store.jobs.sendPreview(job, shown: text) ?? ""
            sending = false
        }
    }
}
