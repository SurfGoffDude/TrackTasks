import SwiftUI
import TrackTasksCore

/// Problems with files in Application Support (corrupt JSON, failed writes), shown as a banner.
@Observable @MainActor
final class StorageIssues {
    static let shared = StorageIssues()
    private(set) var messages: [String] = []

    func report(_ text: String) {
        if !messages.contains(text) { messages.append(text) }
    }

    func dismiss() { messages.removeAll() }

    /// Loads JSON; on corruption keeps a copy, reports it and returns nil.
    func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> T? {
        switch SafeJSON.load(type, from: url, decoder: decoder) {
        case .missing: return nil
        case .value(let v): return v
        case .corrupt(let backup, _):
            let name = url.lastPathComponent
            if let backup {
                report("Файл \(name) повреждён. Копия сохранена: \(backup.lastPathComponent) (в Application Support/TrackTasks). Данные начаты с нуля — восстанови их из копии.")
            } else {
                report("Файл \(name) повреждён, и копию сделать не удалось. Данные начаты с нуля, запись в этот файл отключена, чтобы не затереть оригинал — перенеси его вручную и перезапусти приложение.")
            }
            return nil
        case .unreadable(let error):
            report("Файл \(url.lastPathComponent) не удалось прочитать (\(error)). Файл не тронут, запись в него отключена до перезапуска.")
            return nil
        }
    }

    /// False: not written.
    @discardableResult
    func save(_ data: Data, to url: URL) -> Bool {
        do {
            if let warning = try SafeJSON.save(data, to: url) { report(warning) }
            return true
        } catch {
            report("Не удалось записать \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

struct StorageIssuesBanner: View {
    private var issues: StorageIssues { .shared }

    var body: some View {
        if !issues.messages.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(issues.messages.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Скрыть") { issues.dismiss() }.buttonStyle(.glass)
            }
            .padding(10)
            .background(.orange.opacity(0.15))
        }
    }
}
