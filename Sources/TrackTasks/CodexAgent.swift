import Foundation
import TrackTasksCore

/// Codex CLI over `codex app-server`.
struct CodexAgent: Agent {
    let id = AgentID.codex
    let title = "Codex"
    /// No `.cost` (not reported), `.autoModel`, `.guardedLimit` (Claude's), `.bypass`. Fork isn't checked against a live
    /// server yet. Isolation is always on, so the setting doesn't apply.
    let capabilities: AgentCapabilities = [.resume, .permissions, .requiresWorktree]

    func makeRun() -> any AgentRun { CodexProcess() }
}

enum CodexLocator {
    static let key = "codexPath"

    /// A path from Settings is never replaced by another codex.
    static func resolve() -> String? {
        let fm = FileManager.default
        let own = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return fm.isExecutableFile(atPath: own) ? own : nil }
        let home = NSHomeDirectory(), nvm = "\(home)/.nvm/versions/node"
        var all = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        all += ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).sorted(by: >).map { "\(nvm)/\($0)/bin/codex" }
        all.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        return all.first { fm.isExecutableFile(atPath: $0) }
    }

    static func rulesDirs(_ request: AgentRequest?, env: [String: String]) -> [URL] {
        let own = env["CODEX_HOME"] ?? ""
        let home = own.isEmpty ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
            : URL(fileURLWithPath: own, relativeTo: request?.cwd).absoluteURL
        return CodexRules.dirs(codexHome: home, folders: request.map { [$0.cwd] + $0.addDirs } ?? [])
    }
}

enum CodexError: LocalizedError {
    case notFound
    case rules(String)
    var errorDescription: String? {
        switch self {
        case .notFound: "Не найден codex CLI. Установи Codex или укажи путь в Настройках (⌘,)."
        case .rules(let file):
            "Codex не запущен: правила «\(file)» могут выполнять команды без вопроса и вне песочницы. "
                + "Оставь в них только prefix_rule с decision=\"prompt\" или \"forbidden\" либо убери файл."
        }
    }
}
