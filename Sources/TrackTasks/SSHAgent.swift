import Foundation
import TrackTasksCore

/// Claude on a server of the user, over ssh.
struct SSHAgent: Agent {
    let id = AgentID.ssh
    let title = "Claude по SSH"
    /// Code only in a worktree. No `.autoModel` (Haiku would run on the Mac), `.bypass`, `.fork`, `.resumeAt`.
    let capabilities: AgentCapabilities = [.resume, .permissions, .isolation, .requiresWorktree, .cost, .guardedLimit, .remote, .images]
    var transport = RemoteTransport()
    var dataDir = SSHAgent.dataDir
    var cleanup = RemoteCleanup.shared

    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/remote", isDirectory: true)
    }

    func makeRun() -> any AgentRun { SSHRun(transport: transport, dataDir: dataDir, cleanup: cleanup) }

    /// Host key, git and claude on the server; no tokens are spent.
    nonisolated static func check(_ s: RemoteServer, transport: RemoteTransport = RemoteTransport()) -> String {
        do {
            let i = try RemoteInfo(RemoteLink(s, transport).call(["check", s.claude]))
            return "Готово: \(i.git), claude \(i.claude), папка \(i.root)"
        } catch { return RemoteInfo.explain(error).localizedDescription }
    }
}

/// What `check` answers.
struct RemoteInfo {
    var root = "", git = "", claude = ""

    init(_ text: String) throws {
        for l in text.split(whereSeparator: \.isNewline) {
            guard let eq = l.firstIndex(of: "=") else { continue }
            let v = String(l[l.index(after: eq)...])
            switch l[..<eq] {
            case "root": root = v
            case "git": git = v
            case "claude": claude = v
            default: break
            }
        }
        guard root.hasPrefix("/") else { throw RemoteError.failed("Непонятный ответ сервера (возможно, login shell печатает лишнее)") }
    }

    static func explain(_ e: Error) -> Error {
        switch e {
        case RemoteError.code(RemoteRunner.noGit, _): RemoteError.failed("На сервере нет git")
        case RemoteError.code(RemoteRunner.noClaude, _): RemoteError.failed("На сервере нет claude: установи Claude Code или укажи полный путь в настройках сервера")
        default: e
        }
    }
}

/// Extra callbacks of a run on a server.
@MainActor
protocol RemoteAgentRun: AgentRun {
    /// Bytes of the stream whose events were delivered.
    var onOffset: ((Int) -> Void)? { get set }
    /// The result is here, or there is nothing to take: save this before returning.
    var onReturned: (() -> Void)? { get set }
}
