import CryptoKit
import Foundation

/// Server given by the user where the `ssh` agent works.
public struct RemoteServer: Codable, Hashable, Sendable {
    /// Host name, address or an alias from ~/.ssh/config.
    public var host: String
    public var user: String
    /// 0 = from the ssh config.
    public var port: Int
    /// TrackTasks folder on the server: absolute or relative to the home folder.
    public var folder: String
    /// claude on the server: a name found in PATH or an absolute path.
    public var claude: String

    public init(host: String, user: String = "", port: Int = 0, folder: String = Self.defaultFolder, claude: String = "claude") {
        self.host = host
        self.user = user
        self.port = port
        self.folder = folder
        self.claude = claude
    }

    public static let defaultFolder = ".tracktasks"

    /// Shown to the user.
    public var title: String { (user.isEmpty ? "" : user + "@") + host + (port == 0 ? "" : ":\(port)") }

    /// What is wrong with the settings; nil = fine. Only letters that need no quoting in any remote shell get through.
    public var problem: String? {
        if host.isEmpty { return "Укажи адрес сервера" }
        if host.hasPrefix("-") || !Self.matches(host, "[A-Za-z0-9._:%-]+") { return "Недопустимый адрес сервера" }
        if !user.isEmpty, user.hasPrefix("-") || !Self.matches(user, "[A-Za-z0-9._-]+") { return "Недопустимое имя пользователя" }
        if port < 0 || port > 65535 { return "Порт — от 1 до 65535" }
        if !Self.safePath(folder) || folder == "/" || folder == "." { return "Папка на сервере: латинские буквы, цифры, «.», «_», «-», «/», без «..»" }
        if !Self.safePath(claude) || (claude.contains("/") && !claude.hasPrefix("/")) { return "Путь к claude: имя или полный путь без пробелов и «~»" }
        return nil
    }

    private static func safePath(_ s: String) -> Bool {
        matches(s, "[A-Za-z0-9._/-]+") && !s.hasPrefix("-") && !s.split(separator: "/").contains("..")
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }
}

/// One run on a server. Kept in queue.json so that the app can return to it.
public struct RemoteRun: Codable, Equatable, Sendable {
    public var server: RemoteServer
    public var id: String
    /// Working copy on the server: the same for all turns of a worktree.
    public var work: String
    public var project: String
    /// Bytes of the event stream already shown in the log.
    public var offset: Int
    /// The result was taken (or there was nothing to take).
    public var returned: Bool

    public init(server: RemoteServer, id: String = Self.newID(), work: String, project: String, offset: Int = 0, returned: Bool = false) {
        self.server = server
        self.id = id
        self.work = work
        self.project = project
        self.offset = offset
        self.returned = returned
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }
    /// Stable short name of a local path.
    public static func key(_ s: String) -> String { String(sha256(Data(s.utf8)).prefix(24)) }
    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    public static func isID(_ s: String) -> Bool { RemoteServer.matches(s, "[A-Za-z0-9_-]{1,64}") }

    var isSafe: Bool { server.problem == nil && Self.isID(id) && Self.isID(work) && Self.isID(project) }
    public var problem: String? { server.problem ?? (isSafe ? nil : "Недопустимый идентификатор запуска") }
}

/// The remote part of an `AgentRequest`.
public struct AgentRemote: Sendable {
    public var run: RemoteRun
    /// The run was started earlier: continue watching it.
    public var attach: Bool
    /// Main folder of the project and the job's task file.
    public var main: URL
    public var taskPath: URL?
    /// The task file comes back (a review doesn't change it).
    public var returnsTask: Bool
    public var branch: String
    /// Approved `setup:`, run once per working copy; empty = none.
    public var setup: String

    public init(run: RemoteRun, attach: Bool = false, main: URL, taskPath: URL? = nil, returnsTask: Bool = true,
                branch: String = "", setup: String = "") {
        self.run = run
        self.attach = attach
        self.main = main
        self.taskPath = taskPath
        self.returnsTask = returnsTask
        self.branch = branch
        self.setup = setup
    }
}

/// Local paths in prompts → paths on the server.
public enum RemotePaths {
    /// `code` — the local folder the agent works in, `main` — the project's main folder (tracker files).
    public static func translate(_ text: String, code: String, main: String, remoteCode: String, remoteProject: String) -> String {
        var s = text
        func swap(_ from: String, _ to: String) {
            let p = NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}_-])"#
            s = s.replacingOccurrences(of: p, with: NSRegularExpression.escapedTemplate(for: to), options: .regularExpression)
        }
        if code != main {
            swap(code, remoteCode)
            swap(main, remoteProject)
        } else {
            for f in ["tasks", "about.md", "spectrack.md"] { swap("\(main)/\(f)", "\(remoteProject)/\(f)") }
            swap(main, remoteCode)
        }
        // «tasks/x.md» without a folder: there are no tracker files in the working copy.
        s = s.replacingOccurrences(of: #"(?<![\p{L}\p{N}_./-])tasks/(?=[^\s/]+\.md)"#,
                                   with: NSRegularExpression.escapedTemplate(for: remoteProject + "/tasks/"), options: .regularExpression)
        return s
    }
}
