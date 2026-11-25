import SwiftUI

/// Change one month's payment without touching the rest.
struct MonthAmountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let edit: MonthEdit
    @State private var text = ""

    var body: some View {
        let x = Expenses.shared.expense(edit.expenseID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Сумма за \(MoneyFormat.month(edit.month))").font(.title3.bold())
            if let x {
                Text("«\(x.title.isEmpty ? x.category.title : x.title)» — обычно \(MoneyFormat.amount(x.amount, x.currency))\(x.period.short). Изменится только этот месяц; 0 — платежа не было.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Сумма", text: $text).monospacedDigit().textFieldStyle(.roundedBorder)
                    Text(x.currency)
                }
                HStack {
                    if x.overrides[edit.month] != nil {
                        Button("Вернуть обычную") { Expenses.shared.setOverride(x.id, month: edit.month, amount: nil); dismiss() }
                    }
                    Spacer()
                    Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Сохранить") {
                        Expenses.shared.setOverride(x.id, month: edit.month, amount: parseAmount(text) ?? x.amount)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parseAmount(text) == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let x { text = String(format: "%g", x.overrides[edit.month] ?? x.amount) }
        }
    }
}

// MARK: - Editor

struct ExpenseEditor: View {
    @Environment(Store.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var expense: Expense
    let isNew: Bool
    @State private var amountText = ""
    @State private var projectSearch = ""
    @State private var monthTexts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Новый расход" : "Расход").font(.title2.bold())
            Form {
                Section {
                    TextField("Что (например: OpenAI API, VPS Hetzner, домен .ru)", text: $expense.title)
                    HStack {
                        TextField("Сумма", text: $amountText).monospacedDigit()
                        Picker("", selection: $expense.currency) {
                            ForEach(Expense.currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Picker("Категория", selection: $expense.category) {
                        ForEach(Expense.Category.allCases) { c in Label(c.title, systemImage: c.icon).tag(c) }
                    }
                    Picker("Оплата", selection: $expense.period) {
                        ForEach(Expense.Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker(expense.period == .once ? "Дата" : "Первый платёж", selection: $expense.date, displayedComponents: .date)
                    if expense.period != .once {
                        Toggle("Подписка отменена", isOn: Binding(
                            get: { expense.until != nil },
                            set: { expense.until = $0 ? (expense.until ?? Date()) : nil }))
                        if expense.until != nil {
                            DatePicker("Последний платёж до", selection: Binding(get: { expense.until ?? Date() }, set: { expense.until = $0 }),
                                       displayedComponents: .date)
                        }
                    }
                    TextField("Заметка", text: $expense.note)
                    Toggle("Не включать в выгрузку", isOn: $expense.excludeFromExport)
                }
                Section {
                    projectsPicker
                } header: {
                    Text(expense.projects.isEmpty ? "Проекты: общий расход, без привязки"
                         : expense.projects.count == 1 ? "Проект" : "Проекты: делится поровну на \(expense.projects.count)")
                }
                if expense.period != .once, !isNew {
                    Section("Платежи — можно изменить сумму отдельного месяца") { paymentsList }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Удалить", role: .destructive) { Expenses.shared.remove(expense.id); dismiss() }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled((parseAmount(amountText) ?? 0) <= 0)
            }
        }
        .padding(24)
        .frame(width: 540, height: 680)
        .onAppear {
            amountText = expense.amount > 0 ? String(format: "%g", expense.amount) : ""
            for (k, v) in expense.overrides { monthTexts[k] = String(format: "%g", v) }
        }
    }

    private func save() {
        expense.amount = parseAmount(amountText) ?? 0
        expense.overrides = Expense.overrides(fromTexts: monthTexts, base: expense.amount)
        Expenses.shared.upsert(expense)
        dismiss()
    }

    @ViewBuilder
    private var projectsPicker: some View {
        let selected = Set(expense.projects)
        let q = projectSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = app.projects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let shown = all.filter { selected.contains($0.id) || q.isEmpty || $0.displayName.lowercased().contains(q) || $0.category.lowercased().contains(q) }
        TextField("Найти проект", text: $projectSearch)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown.sorted { selected.contains($0.id) && !selected.contains($1.id) }) { p in
                    Toggle(isOn: Binding(
                        get: { selected.contains(p.id) },
                        set: { on in
                            if on { expense.projects.append(p.id) } else { expense.projects.removeAll { $0 == p.id } }
                        })) {
                        HStack(spacing: 6) {
                            Text(p.displayName)
                            Text(p.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)
        if !expense.projects.isEmpty {
            Button("Снять все — сделать общим без привязки") { expense.projects.removeAll() }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var paymentsList: some View {
        let base = parseAmount(amountText) ?? expense.amount
        let ps = expense.payments(from: .distantPast, includeSkipped: true).reversed()
        if ps.isEmpty {
            Text("Платежей ещё не было").foregroundStyle(.secondary)
        }
        ForEach(Array(ps), id: \.key) { p in
            HStack {
                Text(MoneyFormat.month(p.key)).frame(width: 150, alignment: .leading)
                TextField(String(format: "%g", base), text: Binding(
                    get: { monthTexts[p.key] ?? "" },
                    set: { monthTexts[p.key] = $0.isEmpty ? nil : $0 }))
                    .monospacedDigit()
                Text(expense.currency).foregroundStyle(.secondary)
                if monthTexts[p.key] != nil {
                    Button { monthTexts[p.key] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Вернуть обычную сумму")
                }
            }
        }
    }
}
