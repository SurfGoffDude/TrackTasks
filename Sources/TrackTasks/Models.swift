import Foundation
import SwiftUI
@_exported import TrackTasksCore

// Models, Frontmatter and Codec live in TrackTasksCore; here only UI bits.

extension TaskStatus {
    var color: Color {
        switch self {
        case .todo: .secondary
        case .doing: .blue
        case .done: .green
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .low: .gray
        case .medium: .orange
        case .high: .red
        }
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .active: .green
        case .paused: .orange
        case .archived: .gray
        case .unknown: .purple
        }
    }
}

// MARK: - Templates

enum TaskTemplate: String, CaseIterable, Identifiable {
    case blank, feature, bug, refactor, research
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Пустая"
        case .feature: "Фича"
        case .bug: "Баг"
        case .refactor: "Рефакторинг"
        case .research: "Исследование"
        }
    }

    var icon: String {
        switch self {
        case .blank: "doc"
        case .feature: "sparkles"
        case .bug: "ladybug"
        case .refactor: "hammer"
        case .research: "magnifyingglass"
        }
    }

    var priority: Priority {
        switch self {
        case .bug: .high
        case .refactor: .low
        default: .medium
        }
    }

    var body: String {
        switch self {
        case .blank: ""
        case .feature:
            """
            Что нужно и зачем:

            - [ ]

            ## Критерии готовности
            - [ ] Работает сценарий: …
            - [ ] Проверено вручную
            - [ ] Обновлена документация (если нужно)
            """
        case .bug:
            """
            Как воспроизвести:
            1.

            Ожидается:

            На деле:

            - [ ] Найти причину
            - [ ] Исправить

            ## Критерии готовности
            - [ ] Сценарий воспроизведения больше не ломается
            - [ ] Рядом ничего не сломалось
            """
        case .refactor:
            """
            Что не так сейчас:

            Как должно быть:

            - [ ]

            ## Критерии готовности
            - [ ] Поведение не изменилось
            - [ ] Сборка и тесты проходят
            """
        case .research:
            """
            Вопрос:

            - [ ] Что выяснить

            ## Заметки

            """
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case recent, name, tasks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "По последним изменениям"
        case .name: "По имени"
        case .tasks: "По открытым задачам"
        }
    }
}

struct TimelineEntry: Identifiable {
    let id = UUID()
    let date: String
    let projectID: String
    let projectName: String
    let isCommit: Bool
    let text: String
}

// MARK: - Category colors

enum Palette {
    static func color(for category: String) -> Color {
        switch category.lowercased() {
        case "go": .cyan
        case "python": .yellow
        case "typescript", "javascript": .blue
        case "rust": .orange
        case "swift": .red
        case "java": .brown
        case "c#", "c:c++": .purple
        case "web": .teal
        case "saas": .pink
        case "garmin": .mint
        case "tmp": .indigo
        default: .gray
        }
    }
}
