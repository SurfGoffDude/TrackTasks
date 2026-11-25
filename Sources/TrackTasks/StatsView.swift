import SwiftUI
import Charts
import TrackTasksCore

/// Agent runs over 7/30/90 days — cost, time or turns: by day, model, kind, task and project.
struct StatsView: View {
    @Environment(Store.self) private var store
    @State private var days = 7
    @State private var entries: [Spend.Entry] = []
    @State private var metric = AgentStats.Metric.cost

    var body: some View {
        let total = entries.reduce(0) { $0 + ($1.cost ?? 0) }
        let tokens = entries.reduce(0) { $0 + $1.totalInput + $1.output }
        let unpriced = entries.filter { $0.cost == nil }.count
        let split = entries.filter(\.hasCacheSplit)
        let plain = split.reduce(0) { $0 + $1.input }
        let write = split.reduce(0) { $0 + ($1.cacheWrite ?? 0) }
        let read = split.reduce(0) { $0 + ($1.cacheRead ?? 0) }
        let splitIn = plain + write + read
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Расходы")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Spacer()
                    Picker("Период", selection: $days) {
                        Text("7 дней").tag(7)
                        Text("30 дней").tag(30)
                        Text("90 дней").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    tile(String(format: "$%.2f", total), unpriced > 0 ? "потрачено · без цены: \(unpriced)" : "потрачено", "creditcard", .purple)
                    tile("\(entries.count)", "запусков агентов", "bolt", .blue)
                    tile(ClaudeRunStats.k(tokens), "токенов", "text.word.spacing", .teal)
                    tile(String(format: "$%.2f", days > 0 ? total / Double(days) : 0), "в среднем за день", "calendar", .orange)
                    tile(splitIn > 0 ? "\(Int((Double(read) / Double(splitIn) * 100).rounded()))%" : "—",
                         split.count < entries.count ? "входа из кеша · \(split.count) из \(entries.count) запусков" : "входа из кеша",
                         "arrow.triangle.2.circlepath", .green)
                }

                if splitIn > 0 {
                    card("Входные токены") {
                        VStack(alignment: .leading, spacing: 6) {
                            tokenRow("Обычные (полная цена)", plain, of: splitIn, .orange)
                            tokenRow("Запись в кеш (≈1.25–2× цены)", write, of: splitIn, .pink)
                            tokenRow("Чтение из кеша (≈0.1× цены)", read, of: splitIn, .green)
                            if split.count < entries.count {
                                Text("Без разбивки: \(entries.count - split.count) старых запусков (до учёта кеша).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if entries.isEmpty {
                    ContentUnavailableView("Пока нет данных", systemImage: "chart.bar",
                                           description: Text("Статистика копится с каждым запуском Claude из трекера."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    Picker("Показатель", selection: $metric) {
                        ForEach(AgentStats.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    card("По дням · \(metric.unit)") {
                        Chart(entries) { e in
                            if let v = metric.value(e) {
                                BarMark(x: .value("День", e.date, unit: .day), y: .value(metric.unit, v))
                                    .foregroundStyle(by: .value("Модель", e.model))
                            }
                        }
                        .chartLegend(position: .top, alignment: .leading)
                        .frame(height: 200)
                        let missing = entries.filter { metric.value($0) == nil }.count
                        if missing > 0 {
                            Text("Нет данных: \(missing) из \(entries.count) запусков" + (metric == .cost ? "" : " (время и ходы записываются с этой версии)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        card("По моделям") { table(AgentStats.rows(entries, by: \.model, sort: metric)) }
                        card("По типу запуска") { table(AgentStats.rows(entries, by: \.kind, sort: metric)) }
                    }
                    let tasks = AgentStats.tasks(entries, sort: metric)
                    if !tasks.isEmpty {
                        card("По задачам" + (tasks.count > 15 ? " · 15 из \(tasks.count)" : "")) { table(tasks, limit: 15) }
                    }
                    card("По проектам") { table(AgentStats.rows(entries, by: \.project, sort: metric), limit: 15) }
                }
                PublishedSnapshotsCard()
                AllExpensesCard(days: days)
            }
            .padding(28)
        }
        .background(Backdrop(tint: .purple))
        .navigationTitle("Расходы")
        .task(id: "\(days)-\(Spend.shared.version)") {
            let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            entries = await Task.detached { Spend.load(since: since) }.value
        }
    }

    private func table(_ rows: [AgentStats.Row], limit: Int = 10) -> some View {
        let top = rows.first?.value(metric) ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.prefix(limit)) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.name).lineLimit(1)
                        if !r.detail.isEmpty { Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(r.text(metric)).monospacedDigit()
                        Text("· \(r.runs)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    GeometryReader { g in
                        Capsule().fill(.purple.gradient.opacity(0.6))
                            .frame(width: max(3, g.size.width * (top > 0 ? r.value(metric) / top : 0)))
                    }
                    .frame(height: 4)
                }
                .help("Стоимость: \(r.text(.cost)) · время: \(r.text(.time)) · ходы: \(r.text(.turns)) · запусков: \(r.runs)")
            }
        }
    }

    private func tokenRow(_ label: String, _ n: Int, of total: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text(ClaudeRunStats.k(n)).monospacedDigit()
                Text("· \(total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : 0)%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { g in
                Capsule().fill(color.gradient.opacity(0.6))
                    .frame(width: max(3, g.size.width * (total > 0 ? Double(n) / Double(total) : 0)))
            }
            .frame(height: 4)
        }
    }

    private func tile(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(color.opacity(0.08)), in: .rect(cornerRadius: 16))
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

extension AgentStats.Metric {
    var title: String {
        switch self {
        case .cost: "Стоимость"
        case .time: "Время"
        case .turns: "Ходы"
        }
    }
    var unit: String {
        switch self {
        case .cost: "$"
        case .time: "мин"
        case .turns: "ходы"
        }
    }
}

/// Dashboard block: projects that look abandoned — archive or keep.
struct ArchiveCandidates: View {
    @Environment(Store.self) private var store
    @State private var expanded = false

    var body: some View {
        let items = store.archiveCandidates
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack {
                        Label("Кандидаты в архив: \(items.count)", systemImage: "archivebox")
                            .font(.headline)
                        Text("не трогались 90+ дней, открытых задач нет")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(items) { p in
                        HStack(spacing: 8) {
                            Circle().fill(Palette.color(for: p.category)).frame(width: 7, height: 7)
                            Button { store.selectedID = p.id } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.displayName)
                                    Text("\(p.category) · \(store.lastActivity(p))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("В архив") { store.setProjectStatus(p, .archived) }
                                .buttonStyle(.glass).controlSize(.small)
                            Button("Оставить") { store.keptActive.insert(p.id) }
                                .buttonStyle(.glass).controlSize(.small)
                                .help("Больше не предлагать")
                        }
                    }
                    if items.count > 1 {
                        Button("Архивировать все \(items.count)") {
                            for p in items { store.setProjectStatus(p, .archived) }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.gray.opacity(0.08)), in: .rect(cornerRadius: 18))
        }
    }
}
