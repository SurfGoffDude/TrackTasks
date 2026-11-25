import SwiftUI
import TrackTasksCore

/// Failed checks and the exact message to the agent. Nothing is sent without the button.
struct CIFixSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var draft: CIFix.Draft?
    @State private var chosen: Set<Int> = []
    @State private var note = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Исправить CI · PR #\(job.pullRequest?.pr.number ?? 0)").font(.title3.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).disabled(busy).help("Собрать логи заново")
            }
            Text("Лог — чужой текст: агент получит его как данные. Прочитай, прежде чем отправлять. Push сделаешь ты — «Обновить PR».")
                .font(.caption).foregroundStyle(.secondary)
            if let draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(draft.items.enumerated()), id: \.offset) { i, item in row(i, item) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
                HStack {
                    Text("Уйдёт агенту").font(.headline)
                    let removed = chosen.reduce(0) { $0 + (draft.items[$1].log?.removed ?? 0) }
                    if removed > 0 { Text("вычищено ключей и путей: \(removed)").font(.caption).foregroundStyle(.orange) }
                }
                ScrollView {
                    Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            } else {
                Text(busy ? "Получаю логи через gh…" : "Логи не получены").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !error.isEmpty { Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            TextField("Указание агенту от себя (необязательно)", text: $note, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack {
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Отправить агенту") { send() }
                    .buttonStyle(.glassProminent)
                    .disabled(text.isEmpty || busy || store.jobs.ciFixBlocked(job) != nil)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
        .task { load() }
    }

    private var text: String { draft.map { store.jobs.ciFixText(job, $0, chosen: chosen, note: note) } ?? "" }

    private func row(_ i: Int, _ item: CIFix.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { chosen.contains(i) }, set: { if $0 { chosen.insert(i) } else { chosen.remove(i) } })) {
                Text(verbatim: item.name).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if item.log == nil { Text(verbatim: item.problem).font(.caption).foregroundStyle(.orange).lineLimit(2).help(item.problem) }
            if let l = item.check.link, let u = URL(string: l) { Link("Лог", destination: u).font(.caption).help(l) }
        }
    }

    private func load() {
        guard !busy else { return }
        busy = true
        error = ""
        draft = nil
        Task {
            let r = await store.jobs.prepareCIFix(job)
            busy = false
            switch r {
            case .failure(let e): error = e.text
            case .success(let d):
                draft = d
                chosen = Set(d.items.indices)
            }
        }
    }

    private func send() {
        guard let draft, !busy else { return }
        busy = true
        error = ""
        Task {
            let why = await store.jobs.sendCIFix(job, draft, chosen: chosen, note: note)
            busy = false
            if let why { error = why } else { dismiss() }
        }
    }
}
