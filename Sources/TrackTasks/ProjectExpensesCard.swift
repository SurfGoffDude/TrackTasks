import SwiftUI

struct ProjectExpensesCard: View {
    @Environment(Store.self) private var app
    let project: Project
    @State private var expanded = false
    @State private var editing: Expense?
    @State private var monthEdit: MonthEdit?
    @State private var exporting = false
    @State private var claudeTotal: Double = 0
    @State private var claudeMonth: Double = 0

    private var store: Expenses { Expenses.shared }

    var body: some View {
        let list = store.items(for: project.id)
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let thisMonth = store.spent(project.id, from: monthStart)
        let all = store.spent(project.id, from: .distantPast)
        let perMonth = store.monthly(project.id)

        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Label("Расходы", systemImage: "creditcard").font(.headline)
                    if !list.isEmpty || claudeTotal > 0 {
                        Text("в этом месяце \(MoneyFormat.money(merge(thisMonth, claudeMonth), empty: "0"))")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("хостинг, домены, API-ключи, Claude").font(.callout).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: 10) {
                    tile("Этот месяц", MoneyFormat.money(merge(thisMonth, claudeMonth), empty: "0"))
                    tile("Подписки в месяц", MoneyFormat.money(perMonth, empty: "0"))
                    tile("Всего", MoneyFormat.money(merge(all, claudeTotal), empty: "0"))
                }
                if claudeTotal > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(.purple).frame(width: 22)
                        Text("Claude (из трекера, автоматически)")
                        Spacer()
                        Text(MoneyFormat.amount(claudeMonth, "$") + " в мес · " + MoneyFormat.amount(claudeTotal, "$") + " всего")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                ForEach(list) { x in
                    ExpenseRow(expense: x, project: project.id, edit: { editing = x }, editMonth: { monthEdit = $0 })
                }
                HStack {
                    Button {
                        editing = Expense(projects: [project.id], title: "", amount: 0,
                                          currency: list.first?.currency ?? "₽", category: .hosting,
                                          date: Calendar.current.startOfDay(for: Date()), period: .monthly)
                    } label: { Label("Добавить расход", systemImage: "plus") }
                        .buttonStyle(.glass)
                    Button { exporting = true } label: { Label("Выгрузить…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glass)
                        .disabled(list.isEmpty && claudeTotal == 0)
                    Spacer()
                }
                Text("Хранится только в трекере (не в папке проекта и не в git). Общие расходы делятся между проектами поровну.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .sheet(item: $editing) { x in
            ExpenseEditor(expense: x, isNew: store.expense(x.id) == nil)
        }
        .sheet(item: $monthEdit) { m in MonthAmountSheet(edit: m) }
        .sheet(isPresented: $exporting) { ExpenseExportSheet(projectID: project.id) }
        .task(id: "\(project.id)-\(Spend.shared.version)") {
            let name = project.displayName
            let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
            let entries = await Task.detached { Spend.load(since: .distantPast).filter { $0.project == name } }.value
            claudeTotal = entries.reduce(0) { $0 + ($1.cost ?? 0) }
            claudeMonth = entries.filter { $0.date >= monthStart }.reduce(0) { $0 + ($1.cost ?? 0) }
        }
    }

    private func merge(_ m: Money, _ claude: Double) -> Money {
        ExpenseMath.adding(claude: claude, to: m)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}

struct MonthEdit: Identifiable {
    let expenseID: UUID
    let month: String
    var id: String { "\(expenseID)-\(month)" }
}

/// One expense line; `project` = show this project's share (nil = full amount).
struct ExpenseRow: View {
    @Environment(Store.self) private var app
    let expense: Expense
    var project: String?
    let edit: () -> Void
    let editMonth: (MonthEdit) -> Void

    var body: some View {
        let x = expense
        let k = project.map { x.share($0) } ?? 1
        Button(action: edit) {
            HStack(spacing: 8) {
                Image(systemName: x.category.icon).foregroundStyle(x.category.color).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(x.title.isEmpty ? x.category.title : x.title)
                        if x.isShared {
                            Text("общий · \(x.projects.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.yellow.opacity(0.2), in: .capsule)
                                .help(x.projects.map(name).joined(separator: ", "))
                        } else if x.isGeneral {
                            Text("общий")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.gray.opacity(0.2), in: .capsule)
                        }
                        if x.excludeFromExport {
                            Image(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Не попадает в выгрузку")
                        }
                    }
                    Text(subtitle(x, k)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(MoneyFormat.amount(x.amount * k, x.currency) + x.period.short)
                        .monospacedDigit()
                        .foregroundStyle(x.period != .once && !x.isActive ? .secondary : .primary)
                    if k < 1 {
                        Text("из \(MoneyFormat.amount(x.amount, x.currency))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Изменить") { edit() }
            if x.period != .once {
                let key = Expense.monthKey(Date())
                if x.payments(from: Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date(), includeSkipped: true)
                    .contains(where: { $0.key == key }) {
                    Button("Сумма только за \(MoneyFormat.month(key))…") { editMonth(MonthEdit(expenseID: x.id, month: key)) }
                }
            }
            if x.isActive {
                Button("Отменить подписку с сегодняшнего дня") {
                    var y = x; y.until = Date(); Expenses.shared.upsert(y)
                }
            }
            Button(x.excludeFromExport ? "Включать в выгрузку" : "Не включать в выгрузку") {
                var y = x; y.excludeFromExport.toggle(); Expenses.shared.upsert(y)
            }
            Divider()
            Button("Удалить", role: .destructive) { Expenses.shared.remove(x.id) }
        }
    }

    private func name(_ id: String) -> String {
        app.project(id)?.displayName ?? URL(fileURLWithPath: id).lastPathComponent
    }

    private func subtitle(_ x: Expense, _ k: Double) -> String {
        let ru = Locale(identifier: "ru_RU")
        let d = x.date.formatted(.dateTime.day().month(.abbreviated).year().locale(ru))
        var s: String
        switch x.period {
        case .once: s = "\(x.category.title) · \(d)"
        default:
            let total = x.total(from: .distantPast) * k
            let state = x.isActive ? "с \(d)" : "\(d) – \(x.until?.formatted(.dateTime.day().month(.abbreviated).year().locale(ru)) ?? "")"
            s = "\(x.category.title) · \(state) · всего \(MoneyFormat.amount(total, x.currency))"
        }
        if !x.overrides.isEmpty { s += " · изменено месяцев: \(x.overrides.count)" }
        if x.isShared, project != nil { s += " · доля 1/\(x.projects.count)" }
        return s
    }
}
