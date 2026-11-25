import SwiftUI
import AppKit
import TrackTasksCore

/// «Граф» of a project: columns = waves of «Волнами по приоритету» (`TaskGraph` / `WavePlan`),
/// nodes = tasks, arrows = `depends:` (dependency → dependent).
struct TaskGraphView: View {
    @Environment(Store.self) private var store
    let project: Project
    @Binding var editing: TaskItem?
    var filter = MilestoneFilter.all
    @AppStorage("graphByMilestone") private var byMilestone = false
    @AppStorage("graphShowDone") private var showDone = false

    var body: some View {
        let layout = TaskGraph.build(project.tasks.map(TaskGraph.Task.init), showDone: showDone,
                                      only: filter == .all ? nil : Set(project.tasks.filter(filter.matches).map(\.fileName)),
                                      parked: project.dependencyNodes.filter { $0.value.parked != nil })
        let hasMilestones = project.tasks.contains { !$0.milestone.isEmpty }
        let byName = Dictionary(project.tasks.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })
        let pending = project.tasks.filter { filter.matches($0) && $0.status != .done && store.jobs.job(forTask: $0.id) == nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Toggle("Готовые", isOn: $showDone)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Показывать выполненные задачи (приглушённо)")
                if hasMilestones {
                    Toggle("По вехам", isOn: $byMilestone)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Группировать задачи внутри волн по вехам")
                }
                legend
                Spacer(minLength: 8)
                Button {
                    store.enqueue(pending, project: project, waves: true)
                } label: { Label("Запустить волнами", systemImage: "square.stack.3d.up") }
                .buttonStyle(.glassProminent)
                .disabled(pending.isEmpty)
                .help(QueueModeHelp.waves + "\nВсе невыполненные задачи\(filter == .all ? "" : " выбранной вехи"), ещё не стоящие в очереди.")
            }
            if !layout.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Ошибки в depends", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                    ForEach(layout.errors, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.red.opacity(0.12)), in: .rect(cornerRadius: 14))
            }
            if layout.columns.isEmpty {
                Text(project.tasks.isEmpty ? "Задач пока нет" : filter == .all ? "Все задачи выполнены" : "Все задачи выбранной вехи выполнены")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 44) {
                        ForEach(Array(layout.columns.enumerated()), id: \.offset) { _, column in
                            columnView(column, layout: layout, byName: byName)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .backgroundPreferenceValue(GraphNodeBounds.self) { anchors in
                        GeometryReader { geo in
                            GraphEdges(edges: layout.edges, nodes: layout.nodes,
                                       rects: anchors.mapValues { geo[$0] })
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("можно брать", "play.circle.fill", .green)
            legendItem("ждёт depends", "lock.fill", .orange)
            legendItem("ошибка", "exclamationmark.octagon.fill", .red)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(color) }
    }

    private func columnView(_ column: TaskGraph.Column, layout: TaskGraph.Layout,
                            byName: [String: TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            columnTitle(column.kind)
                .font(.headline)
                .padding(.horizontal, 4)
            if byMilestone, byName.values.contains(where: { !$0.milestone.isEmpty }) {
                ForEach(Milestone.groups(column.tasks, milestone: byName.mapValues(\.milestone)), id: \.milestone) { g in
                    Label(g.milestone.isEmpty ? "Без вехи" : g.milestone, systemImage: "flag")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                    nodeCards(g.tasks, layout: layout, byName: byName)
                }
            } else {
                nodeCards(column.tasks, layout: layout, byName: byName)
            }
        }
        .frame(width: GraphNodeCard.width, alignment: .top)
    }

    private func nodeCards(_ names: [String], layout: TaskGraph.Layout, byName: [String: TaskItem]) -> some View {
        ForEach(names, id: \.self) { name in
            if let t = byName[name], let node = layout.nodes[name] {
                GraphNodeCard(task: t, node: node, selected: store.selectedTasks.contains(t.id),
                              pendingDepends: t.depends.filter { byName[$0].map { $0.status != .done } ?? false }.count)
                    .anchorPreference(key: GraphNodeBounds.self, value: .bounds) { [name: $0] }
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) {
                            store.toggleSelection(t)
                        } else {
                            editing = t
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func columnTitle(_ kind: TaskGraph.ColumnKind) -> some View {
        switch kind {
        case .done:
            Label("Готово", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .wave(let n, let p):
            HStack(spacing: 6) {
                Circle().fill(p.color.gradient).frame(width: 8, height: 8)
                Text("Волна \(n)")
                Text(p.title.lowercased()).foregroundStyle(.secondary).font(.subheadline)
            }
            .help("Волна \(n): задачи приоритета «\(p.title)» и подтянутые в неё зависимости")
        case .errors:
            Label("Не в плане", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                .help("Задачи в цикле depends — в очередь волнами не попадут, пока цикл не разорван")
        }
    }
}

private struct GraphNodeBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct GraphNodeCard: View {
    @Environment(Store.self) private var store
    static let width: CGFloat = 230
    let task: TaskItem
    let node: TaskGraph.Node
    let selected: Bool
    let pendingDepends: Int

    var body: some View {
        let job = store.jobs.job(forTask: task.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(task.priority.color.gradient).frame(width: 8, height: 8)
                    .help("Приоритет: \(task.priority.title)")
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(node.state == .done, color: .secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                stateLabel
                Spacer(minLength: 0)
                if let job {
                    if job.state == .running { ProgressView().controlSize(.mini) }
                    Text(job.state == .running ? "работает" : "в очереди").foregroundStyle(.orange)
                } else if !task.size.isEmpty {
                    Text(task.size.uppercased()).fontWeight(.bold).foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            if !task.milestone.isEmpty {
                Label(task.milestone, systemImage: "flag").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if !node.errors.isEmpty {
                Text(node.errors.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .contentShape(.rect)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 12))
        .overlay {
            if selected || node.state == .error || node.state == .ready {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor, lineWidth: node.state == .ready && !selected ? 1 : 2)
            }
        }
        .opacity(node.state == .done ? 0.5 : 1)
        .help(task.fileName)
    }

    private var borderColor: Color {
        if node.state == .error { return .red }
        if selected { return .accentColor }
        return .green.opacity(0.6)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch node.state {
        case .ready:
            Label("можно брать", systemImage: "play.circle.fill").foregroundStyle(.green)
        case .blocked:
            Label("ждёт: \(pendingDepends)", systemImage: "lock.fill").foregroundStyle(.orange)
        case .done:
            Label(task.completed.isEmpty ? "готово" : task.completed, systemImage: "checkmark").foregroundStyle(.secondary)
        case .error:
            Label("ошибка", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// Arrows dependency → dependent. Forward edges go right edge → left edge; edges inside one column
/// (or backwards) loop around the left side.
private struct GraphEdges: View {
    let edges: [TaskGraph.Edge]
    let nodes: [String: TaskGraph.Node]
    let rects: [String: CGRect]

    var body: some View {
        Canvas { ctx, _ in
            for e in edges {
                guard let a = rects[e.from], let b = rects[e.to] else { continue }
                let bad = nodes[e.from]?.state == .error || nodes[e.to]?.state == .error
                let waits = nodes[e.from]?.state != .done
                let color: Color = bad ? .red : (waits ? .orange : .secondary)
                var path = Path()
                let end: CGPoint
                if b.minX > a.maxX {
                    let s = CGPoint(x: a.maxX, y: a.midY)
                    end = CGPoint(x: b.minX, y: b.midY)
                    let dx = max(20, (end.x - s.x) / 2)
                    path.move(to: s)
                    path.addCurve(to: end, control1: CGPoint(x: s.x + dx, y: s.y),
                                  control2: CGPoint(x: end.x - dx, y: end.y))
                } else {
                    let s = CGPoint(x: a.minX, y: a.midY)
                    end = CGPoint(x: b.minX, y: b.midY)
                    let dx = 18 + min(26, abs(end.y - s.y) / 8)
                    path.move(to: s)
                    path.addCurve(to: end, control1: CGPoint(x: s.x - dx, y: s.y),
                                  control2: CGPoint(x: end.x - dx, y: end.y))
                }
                ctx.stroke(path, with: .color(color.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: bad ? [4, 3] : []))
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                head.closeSubpath()
                ctx.fill(head, with: .color(color.opacity(0.85)))
            }
        }
        .allowsHitTesting(false)
    }
}
