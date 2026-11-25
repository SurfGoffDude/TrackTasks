import SwiftUI
import TrackTasksCore

struct QuickAction: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let run: () -> Void
}

struct ClaudePanel: View {
    let session: ClaudeSession
    let intro: String
    let actions: [QuickAction]
    /// Open tasks for `/tasks`, as Markdown.
    let tasks: () -> String
    @AppStorage(ClaudeModel.storageKey) private var model: ClaudeModel = .auto
    @AppStorage(ClaudeSession.askKey) private var askTask = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            messages
            // Another project: its own suggestions and focus.
            ChatComposer(session: session, actions: actions, tasks: tasks)
                .id(ObjectIdentifier(session))
        }
        // Never let any row force the panel wider than the inspector column.
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
    }

    private var subtitle: String {
        var parts = [session.title]
        if session.totalCost > 0 { parts.append(String(format: "$%.3f", session.totalCost)) }
        if let c = session.context { parts.append(ChatInput.context(c.tokens, window: c.window)) }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.orange.gradient)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Code").font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.context == nil ? session.title : "\(subtitle)\nКонтекст: токены последнего ответа и доля окна модели")
            }
            .layoutPriority(-1)
            Spacer(minLength: 4)
            if session.isRunning {
                ProgressView().controlSize(.small)
            }
            Menu {
                Picker("Модель", selection: $model) {
                    ForEach(ClaudeModel.allCases) { m in
                        Text("\(m.title) — \(m.hint)").tag(m)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model == .auto ? "Модель" : model.title)
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
            .help("Модель Claude: \(model.title) (применяется со следующего сообщения)")
            if session.isRunning {
                Button { session.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Остановить")
            }
            historyMenu
            Button { session.reset() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Новый диалог")
                .disabled(session.messages.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    private var historyMenu: some View {
        Menu {
            if session.history.isEmpty {
                Text("История пуста")
            }
            ForEach(session.history) { r in
                Button {
                    session.open(r)
                } label: {
                    if r.id == session.chatID {
                        Label(r.title, systemImage: "checkmark")
                    } else {
                        Text(r.title)
                    }
                    Text(Self.dateFormat.string(from: r.updated)
                         + (r.totalCost > 0 ? String(format: " · $%.3f", r.totalCost) : ""))
                }
                .disabled(session.isRunning)
            }
            Divider()
            Toggle("Спрашивать: задача или чат", isOn: $askTask)
            if session.history.contains(where: { $0.id == session.chatID }) {
                Divider()
                Button("Удалить текущий диалог", role: .destructive) {
                    session.deleteChat(session.chatID)
                }
                .disabled(session.isRunning)
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
        .help("История диалогов (\(session.history.count))")
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.messages.isEmpty {
                        empty
                    }
                    let last = session.lastRequest?.id
                    ForEach(session.messages) { m in
                        let again = m.id == last
                        ChatMessageRow(message: m, onRepeat: again ? { session.repeatLast() } : nil,
                                       onEdit: again ? { session.editLast() } : nil)
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: session.messages.count) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(intro)
                .font(.callout)
                .foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(actions) { a in
                        Button(action: a.run) {
                            Label(a.title, systemImage: a.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            Text("Claude читает проекты и пишет в tasks/, about.md и spectrack.md. Остальные команды — только с твоего разрешения.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }
}
