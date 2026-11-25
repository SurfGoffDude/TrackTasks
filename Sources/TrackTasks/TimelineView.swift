import SwiftUI

struct TimelineView: View {
    @Environment(Store.self) private var store
    @State private var days = 7
    @State private var entries: [TimelineEntry] = []
    @State private var loading = false
    @State private var showCommits = true

    var body: some View {
        let visible = showCommits ? entries : entries.filter { !$0.isCommit }
        let byDay = Dictionary(grouping: visible, by: \.date).sorted { $0.key > $1.key }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Хроника")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Коммиты", isOn: $showCommits)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Picker("", selection: $days) {
                        Text("Неделя").tag(7)
                        Text("Месяц").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                HStack(spacing: 10) {
                    Stat(value: "\(entries.filter { !$0.isCommit }.count)", label: "задач закрыто",
                         icon: "checkmark.seal.fill", color: .green)
                    Stat(value: "\(entries.filter(\.isCommit).count)", label: "коммитов",
                         icon: "arrow.triangle.branch", color: .indigo)
                    Stat(value: "\(Set(entries.map(\.projectID)).count)", label: "проектов затронуто",
                         icon: "folder.fill", color: .blue)
                }

                if byDay.isEmpty && !loading {
                    ContentUnavailableView("Тишина", systemImage: "moon.zzz",
                                           description: Text("За выбранный период нет закрытых задач и коммитов."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }

                ForEach(byDay, id: \.key) { day, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.pretty(day)).font(.title3.weight(.semibold))
                        GlassEffectContainer(spacing: 8) {
                            VStack(spacing: 6) {
                                ForEach(groupByProject(items), id: \.0) { pid, name, rows in
                                    projectBlock(pid: pid, name: name, rows: rows)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .background(Backdrop(tint: .green))
        .navigationTitle("Хроника")
        .task(id: days) {
            loading = true
            entries = await store.loadTimeline(days: days)
            loading = false
        }
    }

    private func groupByProject(_ items: [TimelineEntry]) -> [(String, String, [TimelineEntry])] {
        var order: [String] = []
        var map: [String: (String, [TimelineEntry])] = [:]
        for e in items {
            if map[e.projectID] == nil { order.append(e.projectID); map[e.projectID] = (e.projectName, []) }
            map[e.projectID]?.1.append(e)
        }
        return order.map { ($0, map[$0]!.0, map[$0]!.1) }
    }

    private func projectBlock(pid: String, name: String, rows: [TimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { store.selectedID = pid } label: {
                HStack {
                    Text(name).font(.headline)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            ForEach(rows) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: e.isCommit ? "arrow.triangle.branch" : "checkmark.circle.fill")
                        .foregroundStyle(e.isCommit ? Color.indigo : Color.green)
                        .font(.caption)
                    Text(e.text)
                        .foregroundStyle(e.isCommit ? .secondary : .primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    static func pretty(_ day: String) -> String {
        let inF = DateFormatter()
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(d) { return "Вчера" }
        let outF = DateFormatter()
        outF.locale = Locale(identifier: "ru_RU")
        outF.dateFormat = "EEEE, d MMMM"
        return outF.string(from: d).capitalized
    }
}
