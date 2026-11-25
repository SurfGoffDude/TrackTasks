import Foundation

/// What `tt queue` and the running app say to each other: one request and one response per connection.
/// The operations below are all there is. Approving (permissions, plans, setup scripts), merging, pull requests,
/// pause and settings are deliberately absent: they stay with a person in the app.
public enum QueueProtocol {
    public static let version = 1
    public static let maxRequest = 1 << 20
    public static let maxResponse = 8 << 20
    /// Log text in one response, before JSON escaping.
    public static let maxLog = 512 << 10
    public static let maxLogLines = 1000
}

public enum QueueOp: String, Codable, CaseIterable, Sendable {
    case list, add, cancel, log, open
    /// A text message to the agent of a finished job; not an answer to a permission request.
    case answer
}

public struct QueueRequest: Codable, Equatable, Sendable {
    public var `protocol` = QueueProtocol.version
    public var op: QueueOp
    /// add: main folder of the project and file names in its tasks/.
    public var project: String?
    public var tasks: [String]?
    public var withDeps: Bool?
    /// cancel, answer, log: job id, unique prefix of it, or a task file name.
    public var job: String?
    public var text: String?
    public var tail: Int?

    public init(_ op: QueueOp, project: String? = nil, tasks: [String]? = nil, withDeps: Bool? = nil,
                job: String? = nil, text: String? = nil, tail: Int? = nil) {
        self.op = op
        self.project = project
        self.tasks = tasks
        self.withDeps = withDeps
        self.job = job
        self.text = text
        self.tail = tail
    }

    /// Version first, then the operation: another version may have other fields.
    static func decode(_ data: Data) throws -> QueueRequest {
        struct Head: Decodable { var `protocol`: Int; var op: String }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else {
            throw QueueFailure(.usage, "запрос не разобран")
        }
        guard head.protocol == QueueProtocol.version else {
            throw QueueFailure(.version, "протокол \(head.protocol), приложение понимает \(QueueProtocol.version)")
        }
        guard QueueOp(rawValue: head.op) != nil else { throw QueueFailure(.usage, "нет операции «\(head.op)»") }
        guard let r = try? JSONDecoder().decode(QueueRequest.self, from: data) else {
            throw QueueFailure(.usage, "неверные параметры операции «\(head.op)»")
        }
        return r
    }
}

public struct QueueFailure: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable { case io, usage, notFound, conflict, invalid, unavailable, version }
    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct QueueJob: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var state: String
    public var title: String
    public var project: String
    public var projectPath: String
    /// Full path of the task file.
    public var taskPath: String?
    public var lastLine: String
    public var waitReason: String
    /// Permission requests waiting for a person.
    public var permissions: Int
    public var awaitingPlan: Bool
    public var awaitsMerge: Bool

    public init(id: String, kind: String, state: String, title: String, project: String, projectPath: String,
                taskPath: String? = nil, lastLine: String = "", waitReason: String = "", permissions: Int = 0,
                awaitingPlan: Bool = false, awaitsMerge: Bool = false) {
        self.id = id
        self.kind = kind
        self.state = state
        self.title = title
        self.project = project
        self.projectPath = projectPath
        self.taskPath = taskPath
        self.lastLine = lastLine
        self.waitReason = waitReason
        self.permissions = permissions
        self.awaitingPlan = awaitingPlan
        self.awaitsMerge = awaitsMerge
    }

    public var isActive: Bool { state == "pending" || state == "running" }
    public var taskFile: String? { taskPath.map { ($0 as NSString).lastPathComponent } }

    /// Job by id, unique id prefix (4+ characters), or task file name: its active run, else the latest one.
    public static func find(_ ref: String, in jobs: [QueueJob]) throws -> QueueJob {
        let low = ref.lowercased()
        if let j = jobs.first(where: { $0.id.lowercased() == low }) { return j }
        let runs = jobs.filter { j in
            j.kind == "runTask" && j.taskFile.map { [low, low + ".md"].contains($0.lowercased()) } == true
        }
        if !runs.isEmpty {
            let active = runs.filter(\.isActive)
            if active.isEmpty, Set(runs.map(\.taskPath)).count == 1 { return runs[runs.count - 1] }
            if active.count == 1 { return active[0] }
            throw ambiguous(ref, active.isEmpty ? runs : active)
        }
        let hits = low.count >= 4 ? jobs.filter { $0.id.lowercased().hasPrefix(low) } : []
        if hits.count > 1 { throw ambiguous(ref, hits) }
        guard let hit = hits.first else { throw QueueFailure(.notFound, "в очереди нет «\(ref)», см. tt queue list --all") }
        return hit
    }

    private static func ambiguous(_ ref: String, _ jobs: [QueueJob]) -> QueueFailure {
        QueueFailure(.notFound, "«\(ref)» подходит к нескольким: "
            + jobs.map { "\($0.id.prefix(8).lowercased()) \($0.title)" }.joined(separator: "; "))
    }
}

public struct QueueResponse: Codable, Equatable, Sendable {
    public var `protocol` = QueueProtocol.version
    public var error: QueueFailure?
    /// list: everything; add: queued; cancel, answer, log: the job in question.
    public var jobs: [QueueJob]?
    public var log: [String]?
    public var paused: Bool?

    public init(error: QueueFailure? = nil, jobs: [QueueJob]? = nil, log: [String]? = nil, paused: Bool? = nil) {
        self.error = error
        self.jobs = jobs
        self.log = log
        self.paused = paused
    }

    /// Last lines of a log that fit the response.
    public static func tail(_ log: [String], _ n: Int) -> [String] {
        var left = QueueProtocol.maxLog
        var out: [String] = []
        for l in log.suffix(min(max(n, 0), QueueProtocol.maxLogLines)).reversed() {
            guard left > 0 else { break }
            let s = l.utf8.count <= left ? l : "…" + String(decoding: l.utf8.suffix(left), as: UTF8.self)
            left -= l.utf8.count
            out.append(s)
        }
        return out.reversed()
    }
}
