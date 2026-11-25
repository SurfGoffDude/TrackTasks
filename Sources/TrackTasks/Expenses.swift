import Foundation
import SwiftUI

// Model and money math: TrackTasksCore/Expenses.swift. Here — storage and UI-only bits.

extension Expense.Category {
    var icon: String {
        switch self {
        case .hosting: "server.rack"
        case .domain: "globe"
        case .api: "key"
        case .service: "app.badge"
        case .ads: "megaphone"
        case .people: "person.2"
        case .hardware: "desktopcomputer"
        case .other: "creditcard"
        }
    }
    var color: Color {
        switch self {
        case .hosting: .blue
        case .domain: .teal
        case .api: .yellow
        case .service: .purple
        case .ads: .orange
        case .people: .pink
        case .hardware: .gray
        case .other: .secondary
        }
    }
}

@Observable @MainActor
final class Expenses {
    static let shared = Expenses()

    private(set) var items: [Expense] = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("expenses.json")
    }

    private init() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let list = StorageIssues.shared.load([Expense].self, from: Self.url, decoder: d) {
            items = list
        }
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { StorageIssues.shared.save(try e.encode(items), to: Self.url) }
        catch { StorageIssues.shared.report("Не удалось закодировать расходы: \(error.localizedDescription)") }
    }

    func items(for project: String) -> [Expense] {
        items.filter { $0.projects.contains(project) }.sorted { $0.date > $1.date }
    }

    func expense(_ id: UUID) -> Expense? { items.first { $0.id == id } }

    func upsert(_ x: Expense) {
        if let i = items.firstIndex(where: { $0.id == x.id }) { items[i] = x } else { items.append(x) }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Change (or reset with nil) the amount of one month's payment only.
    func setOverride(_ id: UUID, month: String, amount: Double?) {
        guard let x = expense(id) else { return }
        upsert(x.settingOverride(month: month, amount: amount))
    }

    /// Project share (or everything, when project is nil).
    func spent(_ project: String? = nil, from: Date, to: Date = Date()) -> Money {
        ExpenseMath.spent(items, project: project, from: from, to: to)
    }

    func monthly(_ project: String? = nil) -> Money {
        ExpenseMath.monthly(items, project: project)
    }

    var projectsWithExpenses: Set<String> { Set(items.flatMap(\.projects)) }
}
