import SwiftUI

// MARK: - All expenses (Расходы screen)

struct AllExpensesCard: View {
    @Environment(Store.self) private var app
    let days: Int
    @State private var editing: Expense?
    @State private var monthEdit: MonthEdit?
    @State private var exporting = false
    @State private var claudeMonth: Double = 0

    var body: some View {
        let ex = Expenses.shared
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let monthName = Date().formatted(.dateTime.month(.wide)).capitalized
        let manualMonth = ex.spent(from: monthStart)
        let thisMonth = withClaude(manualMonth)
        let general = ex.items.filter { $0.projects.count != 1 }.sorted { $0.date > $1.date }
        let rows: [(id: String, name: String, manual: Money, month: Money, monthly: Money)] = ex.projectsWithExpenses.map { id in
            (id, app.project(id)?.displayName ?? URL(fileURLWithPath: id).lastPathComponent,
             ex.spent(id, from: since), ex.spent(id, from: monthStart), ex.monthly(id))
        }
        .filter { !$0.manual.isEmpty || !$0.monthly.isEmpty }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Расходы проектов").font(.headline)
                Text("доли общих расходов делятся между проектами").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    editing = Expense(projects: [], title: "", amount: 0, currency: "$", category: .api,
                                      date: Calendar.current.startOfDay(for: Date()), period: .monthly)
                } label: { Label("Общий расход", systemImage: "plus") }
                    .buttonStyle(.glass)
                    .help("Расход на несколько проектов (делится поровну) или вообще без привязки")
                Button { exporting = true } label: { Label("Выгрузить…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.glass)
            }
            HStack(spacing: 10) {
                tile("Итого за \(monthName.lowercased())", MoneyFormat.money(thisMonth, empty: "0"),
                     claudeMonth > 0.004 ? "все проекты + общие, в т.ч. Claude \(MoneyFormat.amount(claudeMonth, "$"))"
                                         : "все проекты + общие", .purple, big: true)
                tile("Без Claude", MoneyFormat.money(manualMonth, empty: "0"), "оплачено в этом месяце", .blue)
                tile("За \(days) дн.", MoneyFormat.money(ex.spent(from: since), empty: "0"), "без Claude", .teal)
                tile("Подписки в месяц", MoneyFormat.money(ex.monthly(), empty: "0"), "активные сейчас", .orange)
            }
            if !general.isEmpty {
                Divider()
                Text("Общие").font(.subheadline.weight(.semibold))
                ForEach(general) { x in
                    ExpenseRow(expense: x, project: nil, edit: { editing = x }, editMonth: { monthEdit = $0 })
                }
            }
            if !rows.isEmpty {
                Divider()
                HStack {
                    Text("По проектам (с долями общих)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(monthName).frame(width: 110, alignment: .trailing)
                    Text("\(days) дн.").frame(width: 90, alignment: .trailing)
                    Text("в месяц").frame(width: 110, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.id) { r in
                    Button { app.selectedID = r.id } label: {
                        HStack {
                            Text(r.name).lineLimit(1)
                            Spacer()
                            Text(MoneyFormat.money(r.month, empty: "0")).monospacedDigit().fontWeight(.medium)
                                .frame(width: 110, alignment: .trailing)
                            Text(MoneyFormat.money(r.manual, empty: "0")).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Text(r.monthly.isEmpty ? "—" : MoneyFormat.money(r.monthly)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                        }
                        .font(.callout)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if ex.items.isEmpty {
                Text("Пока пусто. Добавляй расходы в карточке проекта или «Общий расход» здесь — например, API-ключ на несколько проектов.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .sheet(item: $editing) { x in ExpenseEditor(expense: x, isNew: ex.expense(x.id) == nil) }
        .sheet(item: $monthEdit) { m in MonthAmountSheet(edit: m) }
        .sheet(isPresented: $exporting) { ExpenseExportSheet(projectID: nil) }
        .task(id: Spend.shared.version) {
            let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
            let entries = await Task.detached { Spend.load(since: start) }.value
            claudeMonth = entries.reduce(0) { $0 + ($1.cost ?? 0) }
        }
    }

    private func withClaude(_ m: Money) -> Money {
        ExpenseMath.adding(claude: claudeMonth, to: m)
    }

    private func tile(_ label: String, _ value: String, _ hint: String, _ color: Color, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font((big ? Font.title2 : .title3).bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(color.opacity(big ? 0.16 : 0.08)), in: .rect(cornerRadius: 14))
    }
}
