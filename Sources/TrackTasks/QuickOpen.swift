import SwiftUI
import TrackTasksCore

/// ⌘P: fuzzy search over tasks, about.md, spectrack.md and docs/ of all projects.
struct QuickOpenSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [QuickSearchIndex.Hit] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Задачи, about, spectrack, docs…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { open(selection) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            if hits.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Начните вводить" : "Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(hits.enumerated()), id: \.element.entry.id, selection: Binding(get: { selection }, set: { selection = $0 ?? 0 })) { i, h in
                        row(h.entry)
                            .tag(i)
                            .contentShape(.rect)
                            .onTapGesture { open(i) }
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { proxy.scrollTo(hits[safe: selection]?.entry.id) }
                }
            }
        }
        .frame(width: 640, height: 420)
        .onAppear { focused = true }
        .task(id: query) {
            // Wait for a pause in typing; the index lives off the main thread.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let found = await store.quickSearch.search(query)
            guard !Task.isCancelled else { return }
            hits = found
            selection = 0
        }
    }

    private func row(_ e: SearchEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(e)).foregroundStyle(e.status?.color ?? .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).lineLimit(1)
                Text("\(e.projectName) · \(label(e.kind))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func icon(_ e: SearchEntry) -> String {
        switch e.kind {
        case .task: e.status?.icon ?? "circle"
        case .about: "info.circle"
        case .spec: "doc.text.magnifyingglass"
        case .doc: "doc.text"
        }
    }

    private func label(_ k: SearchEntry.Kind) -> String {
        switch k {
        case .task: "задача"
        case .about: "описание"
        case .spec: "спецификация"
        case .doc: "docs"
        }
    }

    private func move(_ d: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + d, 0), hits.count - 1)
    }

    private func open(_ i: Int) {
        guard let e = hits[safe: i]?.entry, let p = store.project(e.projectID) else { return }
        dismiss()
        switch e.kind {
        case .task:
            if let t = p.tasks.first(where: { $0.id == e.id }) { store.reveal(t, in: p) } else { store.selectedID = p.id }
        case .about, .spec:
            store.selectedID = p.id
        case .doc:
            store.selectedID = p.id
            store.open(URL(fileURLWithPath: e.id))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
