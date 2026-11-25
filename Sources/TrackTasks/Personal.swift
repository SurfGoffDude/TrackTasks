import Foundation
import EventKit
import AppKit
import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case work, personal
    var id: String { rawValue }
    var title: String { self == .work ? "Работа" : "Личное" }
    var icon: String { self == .work ? "briefcase" : "person" }
}

enum RepeatRule: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekdays, weekly, monthly, yearly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "Никогда"
        case .daily: "Ежедневно"
        case .weekdays: "По будням"
        case .weekly: "Еженедельно"
        case .monthly: "Ежемесячно"
        case .yearly: "Ежегодно"
        }
    }

    init(_ rules: [EKRecurrenceRule]?) {
        guard let r = rules?.first else { self = .never; return }
        switch r.frequency {
        case .daily: self = .daily
        case .weekly: self = (r.daysOfTheWeek?.count ?? 0) == 5 ? .weekdays : .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        @unknown default: self = .never
        }
    }

    var rule: EKRecurrenceRule? {
        switch self {
        case .never: nil
        case .daily: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                         daysOfTheWeek: [.init(.monday), .init(.tuesday), .init(.wednesday), .init(.thursday), .init(.friday)],
                                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case .weekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .monthly: EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

/// "Купить хлеб завтра в 10" → title "Купить хлеб", due tomorrow 10:00. Russian words + NSDataDetector fallback.
enum QuickDate {
    static func parse(_ input: String) -> (title: String, due: Date?, hasTime: Bool) {
        var text = " " + input + " "
        let cal = Calendar.current
        var day: Date?
        let words: [(String, Int)] = [(" послезавтра", 2), (" завтра", 1), (" сегодня", 0)]
        for (w, add) in words where text.lowercased().contains(w + " ") {
            day = cal.date(byAdding: .day, value: add, to: cal.startOfDay(for: Date()))
            if let r = text.range(of: w + " ", options: .caseInsensitive) { text.replaceSubrange(r, with: " ") }
            break
        }
        var hour: Int?, minute = 0
        if let re = try? NSRegularExpression(pattern: "\\s(?:в|at)\\s(\\d{1,2})(?:[:.](\\d{2}))?(?=\\s)", options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let hr = Range(m.range(at: 1), in: text), let h = Int(text[hr]), h < 24 {
            hour = h
            if let mr = Range(m.range(at: 2), in: text), let mm = Int(text[mr]), mm < 60 { minute = mm }
            if let all = Range(m.range, in: text) { text.replaceSubrange(all, with: " ") }
        }
        var due = day
        if let hour {
            let base = day ?? cal.startOfDay(for: Date())
            due = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base)
            if day == nil, let d = due, d < Date() { due = cal.date(byAdding: .day, value: 1, to: d) }
        }
        let title = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        if due == nil, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)), let d = m.date,
           let r = Range(m.range, in: input) {
            var t = input
            t.removeSubrange(r)
            let comps = cal.dateComponents([.hour, .minute], from: d)
            return (t.trimmingCharacters(in: .whitespaces), d, comps.hour != 0 || comps.minute != 0)
        }
        return (title.isEmpty ? input : title, due, hour != nil)
    }
}

/// One reminder, copied out of EventKit (EKReminder isn't Sendable).
struct PersonalTask: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var notes: String
    var done: Bool
    var completedAt: Date?
    var priority: Priority?
    var due: Date?
    var dueHasTime: Bool
    var listID: String
    var created: Date?
    var url = ""
    var repeats: RepeatRule = .never

    var isOverdue: Bool {
        guard let due, !done else { return false }
        return dueHasTime ? due < Date() : due < Calendar.current.startOfDay(for: Date())
    }
    var isDueToday: Bool {
        guard let due else { return false }
        return Calendar.current.isDateInToday(due)
    }

    init(_ r: EKReminder) {
        id = r.calendarItemIdentifier
        title = r.title ?? ""
        notes = r.notes ?? ""
        done = r.isCompleted
        completedAt = r.completionDate
        switch r.priority {
        case 1...4: priority = .high
        case 5: priority = .medium
        case 6...9: priority = .low
        default: priority = nil
        }
        if let c = r.dueDateComponents {
            due = Calendar.current.date(from: c)
            dueHasTime = c.hour != nil
        } else {
            due = nil
            dueHasTime = false
        }
        listID = r.calendar?.calendarIdentifier ?? ""
        created = r.creationDate
        url = r.url?.absoluteString ?? ""
        repeats = RepeatRule(r.recurrenceRules)
    }

    init(title: String, listID: String) {
        id = ""
        self.title = title
        notes = ""
        done = false
        priority = nil
        dueHasTime = false
        self.listID = listID
    }
}

struct PersonalList: Identifiable, Hashable {
    let id: String
    let title: String
    let color: Color
}

/// Apple Reminders as the source of truth. Changes from iPhone/Reminders.app arrive via EKEventStoreChanged.
@Observable @MainActor
final class RemindersStore {
    enum Access { case unknown, granted, denied }

    var access: Access = .unknown
    var lists: [PersonalList] = []
    var tasks: [PersonalTask] = []
    var loading = false
    var error: String?
    /// Reminders has no "in progress" — kept locally per reminder id.
    var doing: Set<String> {
        didSet { UserDefaults.standard.set(Array(doing), forKey: "personalDoing") }
    }

    @ObservationIgnored private let ek = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var started = false

    init() {
        doing = Set(UserDefaults.standard.stringArray(forKey: "personalDoing") ?? [])
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    /// Ask for access (first time) and start syncing.
    func start() {
        guard !started else { return }
        Task { [weak self] in
            guard let self else { return }
            if access != .granted {
                do {
                    let ok = try await ek.requestFullAccessToReminders()
                    access = ok ? .granted : .denied
                } catch {
                    access = .denied
                    self.error = error.localizedDescription
                }
            }
            guard access == .granted else { return }
            started = true
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
            reload()
        }
    }

    func reload() {
        guard access == .granted else { return }
        let cals = ek.calendars(for: .reminder)
        lists = cals
            .map { PersonalList(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        loading = true
        let open = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        let closed = ek.predicateForCompletedReminders(
            withCompletionDateStarting: Calendar.current.date(byAdding: .day, value: -365, to: Date()), ending: nil, calendars: cals)
        Task {
            async let a = fetch(open)
            async let b = fetch(closed)
            let all = await a + b
            tasks = all
            loading = false
            // Forget "in progress" marks of reminders that are gone or done.
            let alive = Set(all.filter { !$0.done }.map(\.id))
            if !doing.isSubset(of: alive) { doing.formIntersection(alive) }
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [PersonalTask] {
        await withCheckedContinuation { cont in
            ek.fetchReminders(matching: predicate) { rs in
                cont.resume(returning: (rs ?? []).map(PersonalTask.init))
            }
        }
    }

    // MARK: Derived

    func list(_ id: String) -> PersonalList? { lists.first { $0.id == id } }

    var defaultListID: String? {
        ek.defaultCalendarForNewReminders()?.calendarIdentifier ?? lists.first?.id
    }

    func status(_ t: PersonalTask) -> TaskStatus {
        t.done ? .done : doing.contains(t.id) ? .doing : .todo
    }

    func openCount(list: String) -> Int {
        tasks.filter { $0.listID == list && !$0.done }.count
    }

    var todayCount: Int { tasks.filter { !$0.done && ($0.isDueToday || $0.isOverdue) }.count }

    // MARK: Writes

    @discardableResult
    func add(_ title: String, listID: String?, due: Date? = nil, hasTime: Bool = false, priority: Priority? = nil) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let r = EKReminder(eventStore: ek)
        r.title = clean
        r.calendar = listID.flatMap { ek.calendar(withIdentifier: $0) } ?? ek.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
            if hasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        if let priority { r.priority = priority == .high ? 1 : priority == .medium ? 5 : 9 }
        return commit(r)
    }

    /// Edit one reminder in place, keeping its status.
    func update(_ id: String, _ change: (inout PersonalTask) -> Void) {
        guard var t = tasks.first(where: { $0.id == id }) else { return }
        change(&t)
        save(t, status: t.done ? .done : status(t))
    }

    func renameList(_ id: String, to title: String) {
        guard let cal = ek.calendar(withIdentifier: id), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        cal.title = title.trimmingCharacters(in: .whitespaces)
        saveList(cal)
    }

    func recolorList(_ id: String, _ color: Color) {
        guard let cal = ek.calendar(withIdentifier: id), let cg = NSColor(color).usingColorSpace(.sRGB)?.cgColor else { return }
        cal.cgColor = cg
        saveList(cal)
    }

    func deleteList(_ id: String) {
        guard let cal = ek.calendar(withIdentifier: id) else { return }
        do { try ek.removeCalendar(cal, commit: true); reload() } catch { self.error = error.localizedDescription }
    }

    private func saveList(_ cal: EKCalendar) {
        do { try ek.saveCalendar(cal, commit: true); reload() } catch { self.error = error.localizedDescription }
    }

    /// Writes title/notes/done/priority/due/list back to Reminders.
    func save(_ t: PersonalTask, status: TaskStatus) {
        guard let r = ek.calendarItem(withIdentifier: t.id) as? EKReminder else { return }
        r.title = t.title
        r.notes = t.notes.isEmpty ? nil : t.notes
        r.isCompleted = status == .done
        let old = PersonalTask(r)
        if old.priority != t.priority {
            r.priority = switch t.priority {
            case .high: 1
            case .medium: 5
            case .low: 9
            case nil: 0
            }
        }
        if old.due != t.due || old.dueHasTime != t.dueHasTime {
            if let due = t.due {
                let parts: Set<Calendar.Component> = t.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                r.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
                if t.dueHasTime, r.alarms?.isEmpty ?? true { r.addAlarm(EKAlarm(absoluteDate: due)) }
            } else {
                r.dueDateComponents = nil
                r.alarms?.forEach { r.removeAlarm($0) }
            }
        }
        if old.url != t.url {
            r.url = t.url.isEmpty ? nil : URL(string: t.url.contains("://") ? t.url : "https://" + t.url)
        }
        if old.repeats != t.repeats {
            r.recurrenceRules?.forEach { r.removeRecurrenceRule($0) }
            if let rule = t.repeats.rule {
                if r.dueDateComponents == nil {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                }
                r.addRecurrenceRule(rule)
            }
        }
        if t.listID != r.calendar?.calendarIdentifier, let cal = ek.calendar(withIdentifier: t.listID) {
            r.calendar = cal
        }
        if status == .doing { doing.insert(t.id) } else { doing.remove(t.id) }
        commit(r)
    }

    /// Just-completed reminders stay visible for a moment, like in Reminders.app.
    var recentlyDone: Set<String> = []

    func setStatus(_ id: String, _ status: TaskStatus) {
        if status == .done {
            recentlyDone.insert(id)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.snappy) { _ = self.recentlyDone.remove(id) }
            }
        }
        guard var t = tasks.first(where: { $0.id == id }) else { return }
        if self.status(t) == status { return }
        t.done = status == .done
        save(t, status: status)
    }

    func delete(_ id: String) {
        guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { return }
        do {
            try ek.remove(r, commit: true)
            doing.remove(id)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func addList(_ title: String) -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let cal = EKCalendar(for: .reminder, eventStore: ek)
        cal.title = clean
        cal.source = ek.defaultCalendarForNewReminders()?.source
            ?? ek.sources.first { $0.sourceType == .calDAV } ?? ek.sources.first { $0.sourceType == .local }
        do {
            try ek.saveCalendar(cal, commit: true)
            reload()
            return cal.calendarIdentifier
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    private func commit(_ r: EKReminder) -> Bool {
        do {
            try ek.save(r, commit: true)
            error = nil
            reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
