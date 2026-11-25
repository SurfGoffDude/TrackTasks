import SwiftUI
import AppKit

// MARK: - Export

struct ExpenseExportSheet: View {
    @Environment(Store.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var projectID: String?

    enum Range: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, month, thisYear, all, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .thisMonth: "Этот месяц"
            case .lastMonth: "Прошлый месяц"
            case .month: "Месяц…"
            case .thisYear: "Этот год"
            case .all: "Всё время"
            case .custom: "Период…"
            }
        }
    }

    struct Line: Identifiable, Hashable {
        let id: String
        let date: Date
        let project: String
        let title: String
        let category: String
        let kind: String
        let amount: Double
        let currency: String
        let full: Double
        let note: String
        let defaultOn: Bool
    }

    @State private var range: Range = .thisMonth
    @State private var from = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var to = Date()
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var includeClaude = true
    @State private var off: Set<String> = []
    @State private var claude: [Spend.Entry] = []
    @State private var result: String?

    private var bounds: (Date, Date) {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .thisMonth: return (cal.dateInterval(of: .month, for: now)?.start ?? now, now)
        case .lastMonth:
            let prev = cal.date(byAdding: .month, value: -1, to: now) ?? now
            let i = cal.dateInterval(of: .month, for: prev)
            return (i?.start ?? now, (i?.end ?? now).addingTimeInterval(-1))
        case .month:
            let i = cal.dateInterval(of: .month, for: month)
            return (i?.start ?? now, min((i?.end ?? now).addingTimeInterval(-1), now))
        case .thisYear: return (cal.dateInterval(of: .year, for: now)?.start ?? now, now)
        case .all: return (.distantPast, now)
        case .custom: return (cal.startOfDay(for: from), cal.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to)
        }
    }

    private func name(_ id: String) -> String {
        app.project(id)?.displayName ?? URL(fileURLWithPath: id).lastPathComponent
    }

    private var lines: [Line] {
        let (a, b) = bounds
        var out: [Line] = []
        for x in Expenses.shared.items {
            let k: Double
            let projectLabel: String
            if let pid = projectID {
                k = x.share(pid)
                guard k > 0 else { continue }
                projectLabel = name(pid)
            } else {
                k = 1
                projectLabel = x.projects.isEmpty ? "Общие" : x.projects.map(name).joined(separator: ", ")
            }
            for p in x.payments(from: a, to: b) {
                let kind = x.period == .once ? "разово" : (x.period == .monthly ? "ежемесячно" : "ежегодно")
                    + (p.overridden ? " (изменено)" : "")
                    + (x.isShared && projectID != nil ? ", доля 1/\(x.projects.count)" : "")
                out.append(Line(id: "\(x.id)-\(p.key)", date: p.date, project: projectLabel,
                                title: x.title.isEmpty ? x.category.title : x.title, category: x.category.title, kind: kind,
                                amount: p.amount * k, currency: x.currency, full: p.amount, note: x.note,
                                defaultOn: !x.excludeFromExport))
            }
        }
        if includeClaude {
            // One line per project per month.
            let names: Set<String>? = projectID.map { [name($0)] }
            var sums: [String: (Date, String, Double)] = [:]
            for e in claude where e.date >= a && e.date <= b && (names?.contains(e.project) ?? true) {
                let key = "\(e.project)|\(Expense.monthKey(e.date))"
                let start = Calendar.current.dateInterval(of: .month, for: e.date)?.start ?? e.date
                let cur = sums[key] ?? (start, e.project.isEmpty ? "—" : e.project, 0)
                sums[key] = (cur.0, cur.1, cur.2 + (e.cost ?? 0))
            }
            for (key, v) in sums where v.2 >= 0.005 {
                out.append(Line(id: "claude-\(key)", date: v.0, project: v.1, title: "Claude (запуски из трекера)",
                                category: "API и ключи", kind: "за месяц", amount: v.2, currency: "$", full: v.2,
                                note: "", defaultOn: true))
            }
        }
        return out.sorted { ($0.date, $0.project, $0.title) < ($1.date, $1.project, $1.title) }
    }

    private func isOn(_ l: Line) -> Bool { l.defaultOn ? !off.contains(l.id) : off.contains(l.id) }
    private func toggle(_ l: Line) {
        if off.contains(l.id) { off.remove(l.id) } else { off.insert(l.id) }
    }

    var body: some View {
        let ls = lines
        let chosen = ls.filter(isOn)
        var total: Money = [:]
        for l in chosen { total[l.currency, default: 0] += l.amount }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Выгрузка расходов").font(.title2.bold())
            HStack(spacing: 12) {
                Picker("Что", selection: $projectID) {
                    Text("Все проекты").tag(String?.none)
                    Divider()
                    ForEach(app.projects.filter { Expenses.shared.projectsWithExpenses.contains($0.id) }
                        .sorted { $0.displayName < $1.displayName }) { p in
                        Text(p.displayName).tag(String?.some(p.id))
                    }
                }
                .frame(maxWidth: 260)
                Picker("Период", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 220)
                Toggle("Claude", isOn: $includeClaude)
            }
            if range == .month {
                HStack(spacing: 6) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(month <= (months.last ?? month))
                    Picker("Месяц", selection: $month) {
                        ForEach(months, id: \.self) { m in Text(monthTitle(m)).tag(m) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(month >= (months.first ?? month))
                }
                .buttonStyle(.glass)
            }
            if range == .custom {
                HStack {
                    DatePicker("с", selection: $from, displayedComponents: .date)
                    DatePicker("по", selection: $to, displayedComponents: .date)
                }
                .fixedSize()
            }
            HStack {
                Text("Выбрано \(chosen.count) из \(ls.count) · \(MoneyFormat.money(total, empty: "0"))")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Все") { off = Set(ls.filter { !$0.defaultOn }.map(\.id)) }
                Button("Ничего") { off = Set(ls.filter(\.defaultOn).map(\.id)) }
            }
            .buttonStyle(.link)
            List {
                ForEach(ls) { l in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { isOn(l) }, set: { _ in toggle(l) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Text(l.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "ru_RU"))))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(l.title).lineLimit(1)
                            Text("\(l.project) · \(l.kind)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(MoneyFormat.amount(l.amount, l.currency)).monospacedDigit()
                    }
                    .opacity(isOn(l) ? 1 : 0.45)
                    .contentShape(.rect)
                    .onTapGesture { toggle(l) }
                }
            }
            .frame(minHeight: 280)
            if ls.contains(where: { !$0.defaultOn }) {
                Text("Расходы с пометкой «Не включать в выгрузку» сняты по умолчанию — можно отметить вручную.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result { Text(result).font(.caption).foregroundStyle(.green) }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить CSV…") { export(chosen) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task {
            claude = await Task.detached { Spend.load(since: .distantPast) }.value
        }
    }

    /// Months from the earliest expense/Claude run up to now, newest first.
    private var months: [Date] {
        let cal = Calendar.current
        let now = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let earliest = (Expenses.shared.items.map(\.date) + claude.map(\.date)).min() ?? now
        var start = cal.dateInterval(of: .month, for: min(earliest, now))?.start ?? now
        if let floor = cal.date(byAdding: .year, value: -10, to: now), start < floor { start = floor }
        var out: [Date] = []
        var d = now
        while d >= start {
            out.append(d)
            guard let p = cal.date(byAdding: .month, value: -1, to: d) else { break }
            d = p
        }
        return out
    }

    private func monthTitle(_ d: Date) -> String {
        d.formatted(.dateTime.month(.wide).year()).capitalized
    }

    private func shiftMonth(_ by: Int) {
        guard let d = Calendar.current.date(byAdding: .month, value: by, to: month) else { return }
        let ms = months
        if let first = ms.first, let last = ms.last, d >= last, d <= first { month = d }
    }

    private func export(_ ls: [Line]) {
        let panel = NSSavePanel()
        let label = projectID.map { name($0) } ?? "все проекты"
        let period = switch range {
        case .custom: "\(Expense.monthKey(from))…\(Expense.monthKey(to))"
        case .month: Expense.monthKey(month)
        default: range.title.lowercased()
        }
        panel.nameFieldStringValue = "Расходы — \(label) — \(period).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Semicolons + decimal comma + BOM: opens correctly in Excel / Numbers with Russian locale.
        func cell(_ s: String) -> String {
            s.contains(";") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        func num(_ v: Double) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"
        var rows = ["Дата;Проект;Название;Категория;Тип;Сумма;Валюта;Полная сумма;Заметка"]
        for l in ls {
            rows.append([df.string(from: l.date), l.project, l.title, l.category, l.kind, num(l.amount), l.currency, num(l.full), l.note]
                .map(cell).joined(separator: ";"))
        }
        var total: Money = [:]
        for l in ls { total[l.currency, default: 0] += l.amount }
        rows.append("")
        for c in total.keys.sorted() { rows.append(";;Итого;;;\(num(total[c] ?? 0));\(c);;") }
        do {
            try ("\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
            result = "Сохранено: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            result = error.localizedDescription
        }
    }
}
