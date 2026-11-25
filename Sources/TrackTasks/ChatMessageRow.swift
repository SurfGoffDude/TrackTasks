import AppKit
import SwiftUI
import TrackTasksCore

struct ChatMessageRow: View {
    let message: ClaudeSession.Message
    /// Set for the last request, outside of an answer.
    var onRepeat: (() -> Void)?
    var onEdit: (() -> Void)?
    /// The session before this request is known: it can be asked again from its place.
    private var branches: Bool { message.base != nil }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 40)
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.35)), in: .rect(cornerRadius: 14))
                        .contextMenu { actions }
                }
                if onRepeat != nil {
                    HStack(spacing: 10) { actions }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: message.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .contextMenu { copy }
                copy
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
        case .tool:
            if let call = message.tool {
                ChatToolCard(title: message.text, call: call)
            } else {
                Label(message.text, systemImage: "gearshape")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 4)
                    .contextMenu { copy }
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .contextMenu { copy }
        case .info:
            if message.local == true {
                MarkdownView(text: message.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .contextMenu { copy }
            } else {
                Label(message.text, systemImage: "chart.bar.xaxis")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .contextMenu { copy }
            }
        }
    }

    private var copy: some View {
        Button { Self.copy(message.text) } label: { Label("Копировать", systemImage: "doc.on.doc") }
            .help("Копировать")
    }

    @ViewBuilder private var actions: some View {
        copy
        if let onRepeat {
            Button(action: onRepeat) { Label("Повторить", systemImage: "arrow.clockwise") }
                .help(branches ? "Повторить запрос в новом диалоге с этого места; прежний останется в истории. Сделанные правки файлов не откатываются"
                      : "Отправить запрос ещё раз новым сообщением")
        }
        if let onEdit {
            Button(action: onEdit) { Label("Изменить", systemImage: "pencil") }
                .help(branches ? "Изменить запрос: ответ начнётся с этого места в новом диалоге. Сделанные правки файлов не откатываются"
                      : "Изменить и отправить новым сообщением")
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A tool call: one line, opens to its command or file and the result.
struct ChatToolCard: View {
    let title: String
    let call: ChatToolCall
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 14)
                    Text(title)
                        .lineLimit(open ? 4 : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    state
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Свернуть" : "Показать вызов и результат")
            if open {
                if !call.detail.isEmpty { block(call.detail) }
                if let r = call.result {
                    block(r.isEmpty ? "Пустой результат" : r, failed: call.state == .failed)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        .padding(.leading, call.parent == nil ? 0 : 14)
        .contextMenu {
            Button("Копировать вызов") { ChatMessageRow.copy(call.detail.isEmpty ? title : call.detail) }
            if let r = call.result { Button("Копировать результат") { ChatMessageRow.copy(r) } }
        }
    }

    private func block(_ text: String, failed: Bool = false) -> some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder private var state: some View {
        switch call.state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").foregroundStyle(.green).help("Готово")
        case .failed: Image(systemName: "xmark").foregroundStyle(.red).help("Ошибка")
        case .interrupted: Image(systemName: "minus.circle").foregroundStyle(.orange).help("Прервано")
        }
    }

    private var icon: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Glob", "Grep": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "gearshape"
        }
    }
}
