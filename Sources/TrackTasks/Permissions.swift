import AppKit
import SwiftUI

/// Bounce the Dock icon when Claude needs an answer and the app is in the background.
enum Attention {
    @MainActor static func request() {
        guard let app = NSApp, !app.isActive else { return }
        app.requestUserAttention(.criticalRequest)
    }
}

/// "Claude wants to run …" with Allow / Always / Deny.
struct PermissionCard: View {
    let request: PermissionRequest
    var context: String? = nil
    var agent = "Claude"
    /// The card's main block: a list of requests has one, with the shortcut.
    var prominent = true
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    private var icon: String {
        switch request.tool {
        case "Bash": "terminal"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "WebFetch", "WebSearch": "globe"
        default: "hand.raised"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent) просит разрешение").font(.callout.weight(.semibold))
                if let context {
                    Text("· \(context)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Label {
                Text(request.title)
                    .font(.callout.monospaced())
                    .lineLimit(8)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
            if !request.note.isEmpty, request.note != request.title {
                Text(request.note).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var buttons: some View {
        if prominent {
            Button("Разрешить") { answer(true, false) }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
        } else {
            Button("Разрешить") { answer(true, false) }
                .buttonStyle(.glass)
        }
        if !request.ruleText.isEmpty {
            Button("Всегда в проекте") { answer(true, true) }
                .buttonStyle(.glass)
                .help("Добавит правило \(request.ruleText) в .claude/settings.local.json проекта")
        }
        Button("Отклонить", role: .destructive) { answer(false, false) }
            .buttonStyle(.glass)
    }
}
