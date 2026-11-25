import SwiftUI
import TrackTasksCore

/// Terminal tabs inside a job's card.
struct TerminalPanel: View {
    @Environment(Store.self) private var store
    let job: Job
    @AppStorage("terminalHeight") private var height = 320.0
    @State private var dragStart: Double?
    @State private var asking = false
    @State private var command = ""

    private var terminals: Terminals { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) { ForEach(terminals.tabs(job)) { tabButton($0) } }
                }
                .scrollIndicators(.hidden)
                addMenu
                Button { terminals.shown.remove(job.id) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Свернуть (процессы продолжат работать)")
            }
            .padding(6)
            Divider()
            if let t = terminals.current(job) {
                if let error = t.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if let why = t.detached {
                        HStack {
                            Label(why, systemImage: "bolt.horizontal.circle").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Подключить") { t.start() }.disabled(t.busy)
                        }
                        .padding(6)
                    }
                    TerminalHost(screen: t.view).padding(4)
                }
            } else {
                Text("Открой вкладку: shell, Claude или процесс").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            resizeHandle
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .popover(isPresented: $asking) { commandSheet }
    }

    private func tabButton(_ t: TerminalTab) -> some View {
        let active = t.id == terminals.current(job)?.id
        return HStack(spacing: 4) {
            Button { terminals.selected[job.id] = t.id } label: {
                Label(t.title, systemImage: icon(t.kind))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                    .fixedSize()
                    .foregroundStyle(t.isRunning ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help((t.command ?? t.folder.path) + (t.tmux == nil ? "" : "\nВ tmux: переживёт перезапуск приложения. Выделенное мышью копируется сразу."))
            if t.tmux != nil {
                Image(systemName: "square.stack.3d.up").font(.caption2).foregroundStyle(.secondary)
            }
            if !t.isRunning {
                Button { t.start() } label: { Image(systemName: "arrow.clockwise").font(.caption2) }
                    .buttonStyle(.borderless)
                    .disabled(t.kind == .claude && store.jobs.terminalClaudeBlocked(job) != nil)
                    .help("Запустить снова")
            }
            Button { terminals.close(t, of: job.id) } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .help(t.tmux == nil ? "Закрыть вкладку и завершить её процессы" : "Закрыть вкладку и завершить её сессию tmux")
        }
        .contextMenu {
            if let tmux = t.tmux, t.isRunning {
                Button("Скопировать команду attach") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tmux.attachCommand(t.id), forType: .string)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
    }

    private var addMenu: some View {
        Menu {
            Button("Shell", systemImage: icon(.shell)) { terminals.open(job, .shell) }
            if let sid = job.sessionID, job.agentID == .claude {
                let why = store.jobs.terminalClaudeBlocked(job)
                Button(why.map { "Claude: \($0)" } ?? "Claude (продолжить диалог)", systemImage: icon(.claude)) {
                    terminals.open(job, .claude, command: store.claudeCommand(resume: sid))
                }
                .disabled(why != nil)
            }
            Button("Процесс…", systemImage: icon(.command)) {
                if command.isEmpty { command = job.verifyCommand ?? "" }
                asking = true
            }
            Divider()
            Button("Во внешнем терминале") {
                terminals.markUsed(job)
                store.openTerminal(at: job.runDir)
            }
        } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Новая вкладка")
    }

    private var commandSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Процесс в папке задачи").font(.headline)
            TextField("Команда: сервер, сборка, тесты", text: $command)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(runCommand)
            HStack {
                Spacer()
                Button("Отмена") { asking = false }
                Button("Запустить", action: runCommand).buttonStyle(.glassProminent).disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
    }

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func runCommand() {
        guard !trimmed.isEmpty else { return }
        asking = false
        terminals.open(job, .command, command: trimmed)
    }

    private var resizeHandle: some View {
        Capsule().fill(.quaternary).frame(width: 36, height: 4)
            .frame(maxWidth: .infinity).frame(height: 10)
            .contentShape(.rect)
            .pointerStyle(.rowResize)
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { g in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start + g.translation.height, 160), 900)
                }
                .onEnded { _ in dragStart = nil })
    }

    private func icon(_ k: TerminalTab.Kind) -> String {
        switch k {
        case .shell: "terminal"
        case .claude: "sparkles"
        case .command: "gearshape"
        }
    }
}

/// Shows a tab's long-living screen; it outlives this view.
private struct TerminalHost: NSViewRepresentable {
    let screen: TerminalScreen

    func makeNSView(context: Context) -> Container { Container() }
    func updateNSView(_ v: Container, context: Context) { v.show(screen) }
    static func dismantleNSView(_ v: Container, coordinator: ()) { v.subviews.forEach { $0.removeFromSuperview() } }

    final class Container: NSView {
        func show(_ s: TerminalScreen) {
            guard s.superview !== self else { return }
            subviews.forEach { $0.removeFromSuperview() }
            addSubview(s)
            needsLayout = true
            DispatchQueue.main.async { [weak self] in
                guard let self, s.superview === self else { return }
                self.window?.makeFirstResponder(s)
            }
        }

        override func layout() {
            super.layout()
            // Transient tiny sizes would reflow the program's output to a couple of columns.
            guard bounds.width > 80, bounds.height > 40 else { return }
            for s in subviews where s.frame != bounds { s.frame = bounds }
        }
    }
}
