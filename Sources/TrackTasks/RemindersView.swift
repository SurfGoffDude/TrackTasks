import SwiftUI
import AppKit

// Personal mode, laid out like Reminders.app: smart tiles, "My Lists", inline list with quick add.

private let listPalette: [(String, Color)] = [
    ("Красный", .red), ("Оранжевый", .orange), ("Жёлтый", .yellow), ("Зелёный", .green),
    ("Голубой", .cyan), ("Синий", .blue), ("Фиолетовый", .purple), ("Розовый", .pink), ("Коричневый", .brown), ("Серый", .gray),
]

struct PersonalSidebar: View {
    @Environment(Store.self) private var store
    @State private var newList = ""
    @State private var addingList = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: PersonalList?

    var body: some View {
        @Bindable var store = store
        let rs = store.reminders
        List(selection: $store.personalSelection) {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile(PersonalRoot.todayID, "Сегодня", "calendar", .blue, rs.todayCount)
                    tile(PersonalRoot.scheduledID, "Запланировано", "calendar.badge.clock", .red,
                         rs.tasks.filter { !$0.done && $0.due != nil }.count)
                    tile(PersonalRoot.allID, "Все", "tray.fill", .gray, rs.tasks.filter { !$0.done }.count)
                    tile(PersonalRoot.completedID, "Завершено", "checkmark", .secondary, nil)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            }

            Section("Мои списки") {
                ForEach(rs.lists) { l in
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(l.color.gradient)
                            Image(systemName: "list.bullet").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                        .frame(width: 24, height: 24)
                        if renaming == l.id {
                            TextField("Название", text: $renameText)
                                .textFieldStyle(.plain)
                                .onSubmit { rs.renameList(l.id, to: renameText); renaming = nil }
                                .onExitCommand { renaming = nil }
                        } else {
                            Text(l.title).lineLimit(1)
                        }
                        Spacer()
                        let n = rs.openCount(list: l.id)
                        if n > 0 { Text("\(n)").monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 1)
                    .tag(l.id)
                    .contextMenu {
                        Button("Переименовать") { renameText = l.title; renaming = l.id }
                        Menu("Цвет") {
                            ForEach(listPalette, id: \.0) { name, c in
                                Button { rs.recolorList(l.id, c) } label: {
                                    Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(c) }
                                }
                            }
                        }
                        Divider()
                        Button("Удалить список…", role: .destructive) { deleting = l }
                    }
                }
                if addingList {
                    HStack(spacing: 9) {
                        Circle().fill(.blue.gradient).frame(width: 24, height: 24)
                        TextField("Новый список", text: $newList)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                if let id = rs.addList(newList) { store.personalSelection = id }
                                newList = ""
                                addingList = false
                            }
                            .onExitCommand { addingList = false; newList = "" }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { addingList = true } label: {
                Label("Добавить список", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .disabled(rs.access != .granted)
        }
        .confirmationDialog("Удалить список «\(deleting?.title ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Удалить вместе с напоминаниями", role: .destructive) {
                if let d = deleting {
                    rs.deleteList(d.id)
                    if store.personalSelection == d.id { store.personalSelection = PersonalRoot.todayID }
                }
                deleting = nil
            }
        } message: {
            Text("Список и все его напоминания удалятся и на других устройствах.")
        }
        .onAppear { rs.start() }
    }

    private func tile(_ id: String, _ title: String, _ icon: String, _ color: Color, _ count: Int?) -> some View {
        let selected = store.personalSelection == id
        return Button { store.personalSelection = id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ZStack {
                        Circle().fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(color.gradient))
                        Image(systemName: icon).font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selected ? color : .white)
                    }
                    .frame(width: 26, height: 26)
                    Spacer()
                    if let count {
                        Text("\(count)").font(.title2.bold().monospacedDigit())
                            .foregroundStyle(selected ? .white : .primary)
                    }
                }
                Text(title).font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.primary.opacity(0.07)),
                        in: .rect(cornerRadius: 11))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Personal mode detail: access states, then list (default) or board.
struct PersonalDetail: View {
    @Environment(Store.self) private var store
    @AppStorage("personalBoard") private var board = false

    var body: some View {
        let rs = store.reminders
        Group {
            switch rs.access {
            case .granted:
                let filter = store.personalSelection ?? PersonalRoot.todayID
                if board && filter != PersonalRoot.completedID {
                    PersonalBoard(filter: filter).id(filter)
                } else {
                    RemindersList(filter: filter).id(filter)
                }
            case .denied:
                ContentUnavailableView {
                    Label("Нет доступа к Напоминаниям", systemImage: "lock")
                } description: {
                    Text("Разреши TrackTasks в Системные настройки → Конфиденциальность → Напоминания.")
                } actions: {
                    Button("Открыть настройки") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                    }
                    .buttonStyle(.glassProminent)
                }
            case .unknown:
                ContentUnavailableView("Подключаю Напоминания…", systemImage: "checklist")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Вид", selection: $board) {
                    Label("Список", systemImage: "list.bullet").tag(false)
                    Label("Доска", systemImage: "rectangle.split.3x1").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Список — как в Напоминаниях, доска — колонки со статусом «В работе»")
            }
        }
        .onAppear { rs.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rs.reload()
        }
    }
}

// MARK: - List

struct RemindersList: View {
    @Environment(Store.self) private var store
    let filter: String
    @AppStorage("showCompleted") private var showCompleted = false

    private struct Group: Identifiable {
        let id: String
        let title: String?
        let color: Color?
        let items: [PersonalTask]
        /// Where a new reminder typed in this group goes.
        let addList: String?
        let addDue: Date?
        let canAdd: Bool
    }

    private var rs: RemindersStore { store.reminders }
    private var isList: Bool { !PersonalRoot.smart.contains(filter) }

    private var title: String {
        switch filter {
        case PersonalRoot.todayID: "Сегодня"
        case PersonalRoot.scheduledID: "Запланировано"
        case PersonalRoot.allID: "Все"
        case PersonalRoot.completedID: "Завершено"
        default: rs.list(filter)?.title ?? "Список"
        }
    }

    private var color: Color {
        switch filter {
        case PersonalRoot.todayID: .blue
        case PersonalRoot.scheduledID: .red
        case PersonalRoot.allID: .primary
        case PersonalRoot.completedID: .secondary
        default: rs.list(filter)?.color ?? .accentColor
        }
    }

    private func visible(_ t: PersonalTask) -> Bool {
        filter == PersonalRoot.completedID ? t.done : (!t.done || showCompleted || rs.recentlyDone.contains(t.id))
    }

    private func sorted(_ ts: [PersonalTask]) -> [PersonalTask] {
        ts.sorted { a, b in
            if a.done != b.done { return !a.done }
            if filter == PersonalRoot.completedID { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return isList ? false : true
            case (nil, _?): return isList ? true : false
            default: return (a.created ?? .distantPast) < (b.created ?? .distantPast)
            }
        }
    }

    private var groups: [Group] {
        let q = store.search.trimmingCharacters(in: .whitespaces).lowercased()
        var all = rs.tasks.filter(visible)
        if !q.isEmpty { all = all.filter { $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q) } }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch filter {
        case PersonalRoot.todayID:
            let items = all.filter { $0.isDueToday || $0.isOverdue || ($0.done && $0.completedAt.map(cal.isDateInToday) == true) }
            let overdue = items.filter { $0.isOverdue && !$0.isDueToday }
            let rest = items.filter { !($0.isOverdue && !$0.isDueToday) }
            var out: [Group] = []
            if !overdue.isEmpty {
                out.append(Group(id: "overdue", title: "Просрочено", color: .red, items: sorted(overdue), addList: nil, addDue: nil, canAdd: false))
            }
            out.append(Group(id: "today", title: overdue.isEmpty ? nil : "Сегодня", color: nil, items: sorted(rest),
                             addList: rs.defaultListID, addDue: today, canAdd: true))
            return out
        case PersonalRoot.scheduledID:
            let items = all.filter { $0.due != nil }
            var byDay: [Date: [PersonalTask]] = [:]
            var overdue: [PersonalTask] = []
            for t in items {
                guard let d = t.due else { continue }
                let day = cal.startOfDay(for: d)
                if day < today && !t.done { overdue.append(t) } else { byDay[day, default: []].append(t) }
            }
            if byDay[today] == nil { byDay[today] = [] }
            var out: [Group] = []
            if !overdue.isEmpty {
                out.append(Group(id: "overdue", title: "Просрочено", color: .red, items: sorted(overdue), addList: nil, addDue: nil, canAdd: false))
            }
            for day in byDay.keys.sorted() {
                out.append(Group(id: "\(day.timeIntervalSince1970)", title: dayTitle(day), color: nil, items: sorted(byDay[day] ?? []),
                                 addList: rs.defaultListID, addDue: day, canAdd: day >= today))
            }
            return out
        case PersonalRoot.allID, PersonalRoot.completedID:
            let done = filter == PersonalRoot.completedID
            return rs.lists.compactMap { l in
                let items = all.filter { $0.listID == l.id }
                if items.isEmpty && (done || !q.isEmpty) { return nil }
                return Group(id: l.id, title: l.title, color: l.color, items: sorted(items), addList: l.id, addDue: nil, canAdd: !done)
            }
        default:
            return [Group(id: filter, title: nil, color: nil, items: sorted(all.filter { $0.listID == filter }),
                          addList: filter, addDue: nil, canAdd: true)]
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сегодня" }
        if cal.isDateInTomorrow(d) { return "Завтра" }
        let ru = Locale(identifier: "ru_RU")
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: d).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide).locale(ru)).capitalized + ", " + d.formatted(.dateTime.day().month(.wide).locale(ru))
        }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return sameYear ? d.formatted(.dateTime.day().month(.wide).weekday(.abbreviated).locale(ru))
                        : d.formatted(.dateTime.day().month(.wide).year().locale(ru))
    }

    var body: some View {
        let gs = groups
        let count = filter == PersonalRoot.completedID
            ? gs.reduce(0) { $0 + $1.items.count }
            : gs.reduce(0) { $0 + $1.items.filter { !$0.done }.count }
        let completedHere = filter == PersonalRoot.completedID ? 0 : completedCount
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                }
                if filter != PersonalRoot.completedID {
                    HStack {
                        Text(completedHere == 0 ? "Нет завершённых" : "Завершено: \(completedHere)")
                        Text("·")
                        Button(showCompleted ? "Скрыть" : "Показать") { withAnimation(.snappy) { showCompleted.toggle() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(color == .primary ? Color.accentColor : color)
                            .disabled(completedHere == 0 && !showCompleted)
                        Spacer()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                if let e = rs.error {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.top, 6)
                }

                ForEach(gs) { g in
                    VStack(alignment: .leading, spacing: 0) {
                        if let t = g.title {
                            Text(t)
                                .font(.title3.bold())
                                .foregroundStyle(g.color ?? .primary)
                                .padding(.top, 22)
                                .padding(.bottom, 4)
                            Divider()
                        }
                        ForEach(g.items) { t in
                            ReminderRow(task: t, color: rs.list(t.listID)?.color ?? .accentColor,
                                        showList: !isList && filter != PersonalRoot.allID && filter != PersonalRoot.completedID)
                        }
                        if g.canAdd {
                            NewReminderRow(listID: g.addList, due: g.addDue,
                                           color: g.addList.flatMap { rs.list($0)?.color } ?? .accentColor,
                                           autofocus: isList && g.items.isEmpty)
                        }
                    }
                }
                if gs.allSatisfy({ $0.items.isEmpty }) && filter == PersonalRoot.completedID {
                    Text("Нет завершённых напоминаний").foregroundStyle(.secondary).padding(.top, 30)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .navigationTitle(title)
    }

    private var completedCount: Int {
        let cal = Calendar.current
        let ts = rs.tasks.filter(\.done)
        switch filter {
        case PersonalRoot.todayID: return ts.filter { $0.completedAt.map(cal.isDateInToday) == true }.count
        case PersonalRoot.scheduledID: return ts.filter { $0.due != nil }.count
        case PersonalRoot.allID: return ts.count
        default: return ts.filter { $0.listID == filter }.count
        }
    }
}

// MARK: - Rows

struct ReminderRow: View {
    @Environment(Store.self) private var store
    let task: PersonalTask
    let color: Color
    var showList = false
    @State private var title = ""
    @State private var hovering = false
    @State private var showInfo = false
    @FocusState private var focused: Bool

    var body: some View {
        let rs = store.reminders
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    withAnimation(.snappy) { rs.setStatus(task.id, task.done ? .todo : .done) }
                } label: {
                    ZStack {
                        Circle().strokeBorder(task.done ? color : Color.secondary.opacity(0.6), lineWidth: 1.5)
                        if task.done { Circle().fill(color).padding(3.5) }
                    }
                    .frame(width: 19, height: 19)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let p = task.priority {
                            Text(p == .high ? "!!!" : p == .medium ? "!!" : "!")
                                .fontWeight(.bold)
                                .foregroundStyle(task.done ? .secondary : color)
                        }
                        TextField("", text: $title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .focused($focused)
                            .onSubmit(commitTitle)
                    }
                    let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty {
                        Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if !task.url.isEmpty, let u = URL(string: task.url.contains("://") ? task.url : "https://" + task.url) {
                        Link(destination: u) {
                            Label(u.host() ?? task.url, systemImage: "safari")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.07), in: .capsule)
                        }
                    }
                    meta
                }
                Spacer(minLength: 0)
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle").font(.title3).foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .opacity(hovering || showInfo || focused ? 1 : 0)
                .help("Подробности")
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    ReminderInfo(task: task)
                }
            }
            .padding(.vertical, 8)
            Divider().padding(.leading, 29)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onAppear { title = task.title }
        .onChange(of: task.title) { if !focused { title = task.title } }
        .onChange(of: focused) { if !focused { commitTitle() } }
        .contextMenu { menu }
        .transition(.opacity)
    }

    @ViewBuilder
    private var meta: some View {
        let parts = metaParts
        if !parts.isEmpty || (showList && store.reminders.list(task.listID) != nil) {
            HStack(spacing: 6) {
                if let due = task.due {
                    Text(dueText(due)).foregroundStyle(task.isOverdue ? .red : .secondary)
                }
                if task.repeats != .never {
                    Image(systemName: "repeat").foregroundStyle(.secondary).help(task.repeats.title)
                }
                if showList, let l = store.reminders.list(task.listID) {
                    Text(l.title).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var metaParts: [String] {
        var p: [String] = []
        if task.due != nil { p.append("due") }
        if task.repeats != .never { p.append("repeat") }
        return p
    }

    @ViewBuilder
    private var menu: some View {
        let rs = store.reminders
        Button(task.done ? "Отметить невыполненным" : "Выполнено") { rs.setStatus(task.id, task.done ? .todo : .done) }
        Button("Подробности…") { showInfo = true }
        Divider()
        Menu("Срок") {
            Button("Сегодня") { setDue(0) }
            Button("Завтра") { setDue(1) }
            Button("На выходных") {
                let cal = Calendar.current
                let sat = cal.nextDate(after: Date(), matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? Date()
                rs.update(task.id) { $0.due = cal.startOfDay(for: sat); $0.dueHasTime = false }
            }
            Button("Через неделю") { setDue(7) }
            if task.due != nil {
                Divider()
                Button("Убрать срок") { rs.update(task.id) { $0.due = nil; $0.dueHasTime = false; $0.repeats = .never } }
            }
        }
        Menu("Приоритет") {
            ForEach([Priority?.none, .low, .medium, .high], id: \.self) { p in
                Button { rs.update(task.id) { $0.priority = p } } label: {
                    if task.priority == p { Label(p?.title ?? "Нет", systemImage: "checkmark") } else { Text(p?.title ?? "Нет") }
                }
            }
        }
        Menu("Список") {
            ForEach(rs.lists) { l in
                Button { rs.update(task.id) { $0.listID = l.id } } label: {
                    if task.listID == l.id { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                }
            }
        }
        Divider()
        Button("Удалить", role: .destructive) { withAnimation(.snappy) { rs.delete(task.id) } }
    }

    private func setDue(_ days: Int) {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))
        store.reminders.update(task.id) { $0.due = d; $0.dueHasTime = false }
    }

    private func commitTitle() {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != task.title else { return }
        if clean.isEmpty { title = task.title; return }
        store.reminders.update(task.id) { $0.title = clean }
    }

    private func dueText(_ d: Date) -> String {
        let cal = Calendar.current
        let ru = Locale(identifier: "ru_RU")
        let c = cal.dateComponents([.hour, .minute], from: d)
        let time = task.dueHasTime && (c.hour != 0 || c.minute != 0) ? ", " + d.formatted(date: .omitted, time: .shortened) : ""
        if cal.isDateInToday(d) { return "Сегодня" + time }
        if cal.isDateInTomorrow(d) { return "Завтра" + time }
        if cal.isDateInYesterday(d) { return "Вчера" + time }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return (sameYear ? d.formatted(.dateTime.day().month(.abbreviated).locale(ru))
                         : d.formatted(.dateTime.day().month(.abbreviated).year().locale(ru))) + time
    }
}

/// Empty circle + text field at the end of a list; Return adds and keeps typing.
struct NewReminderRow: View {
    @Environment(Store.self) private var store
    let listID: String?
    let due: Date?
    let color: Color
    var autofocus = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = QuickDate.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().strokeBorder(focused ? Color.secondary.opacity(0.6) : .clear, lineWidth: 1.5)
                    .overlay { if !focused { Image(systemName: "plus").font(.caption.bold()).foregroundStyle(color) } }
                    .frame(width: 19, height: 19)
                TextField("Новое напоминание", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand { text = ""; focused = false }
            }
            .padding(.vertical, 8)
            if focused, !text.isEmpty, let d = parsed.due {
                Label(d.formatted(.dateTime.day().month(.wide).hour(parsed.hasTime ? .defaultDigits(amPM: .omitted) : .omitted)
                    .minute(parsed.hasTime ? .twoDigits : .omitted).locale(Locale(identifier: "ru_RU"))),
                      systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(color)
                    .padding(.leading, 29)
                    .padding(.bottom, 6)
            }
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }

    private func add() {
        let p = QuickDate.parse(text)
        var due = p.due ?? due
        var hasTime = p.hasTime
        if p.due == nil { hasTime = false }
        // "!!" / "!!!" prefix = priority, like typing in Reminders.
        var title = p.title
        var priority: Priority?
        if title.hasPrefix("!!!") { priority = .high; title.removeFirst(3) }
        else if title.hasPrefix("!!") { priority = .medium; title.removeFirst(2) }
        else if title.hasPrefix("! ") { priority = .low; title.removeFirst(1) }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if due != nil, p.due == nil { due = Calendar.current.startOfDay(for: due!) }
        if store.reminders.add(title, listID: listID ?? store.reminders.defaultListID, due: due, hasTime: hasTime, priority: priority) {
            text = ""
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// The (i) popover: everything Reminders lets you set that EventKit exposes.
struct ReminderInfo: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var task: PersonalTask
    @State private var original: PersonalTask?

    var body: some View {
        let rs = store.reminders
        VStack(alignment: .leading, spacing: 12) {
            TextField("Название", text: $task.title, axis: .vertical)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
            TextField("Заметки", text: $task.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...8)
                .foregroundStyle(.secondary)
            TextField("URL", text: $task.url)
                .textFieldStyle(.plain)
                .foregroundStyle(.blue)
            Divider()
            Toggle(isOn: Binding(get: { task.due != nil }, set: { task.due = $0 ? (task.due ?? Calendar.current.startOfDay(for: Date())) : nil; if !$0 { task.dueHasTime = false; task.repeats = .never } })) {
                Label("Дата", systemImage: "calendar").foregroundStyle(.red)
            }
            if task.due != nil {
                DatePicker("", selection: Binding(get: { task.due ?? Date() }, set: { task.due = $0 }), displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                Toggle(isOn: Binding(get: { task.dueHasTime }, set: { on in
                    task.dueHasTime = on
                    if on, let d = task.due, Calendar.current.component(.hour, from: d) == 0 {
                        task.due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
                    }
                })) {
                    Label("Время", systemImage: "clock").foregroundStyle(.blue)
                }
                if task.dueHasTime {
                    DatePicker("", selection: Binding(get: { task.due ?? Date() }, set: { task.due = $0 }), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                Picker(selection: $task.repeats) {
                    ForEach(RepeatRule.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Повтор", systemImage: "repeat")
                }
            }
            Divider()
            Picker(selection: $task.priority) {
                Text("Нет").tag(Priority?.none)
                ForEach(Priority.allCases) { Text($0.title).tag(Priority?.some($0)) }
            } label: {
                Label("Приоритет", systemImage: "exclamationmark").foregroundStyle(.orange)
            }
            Picker(selection: $task.listID) {
                ForEach(rs.lists) { l in
                    Label { Text(l.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(l.color) }.tag(l.id)
                }
            } label: {
                Label("Список", systemImage: "list.bullet")
            }
            HStack {
                Button("Удалить", role: .destructive) { rs.delete(task.id); original = nil; dismiss() }
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { original = task }
        .onDisappear {
            if let o = original, o != task { rs.update(task.id) { $0 = task } }
        }
    }
}
