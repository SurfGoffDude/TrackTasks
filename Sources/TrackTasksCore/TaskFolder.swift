import Foundation

/// Where a task file lies: `tasks/`, `tasks/archive/` (read only) or `tasks/drafts/` (never queued).
public enum TaskFolder: String, CaseIterable, Identifiable, Sendable {
    case active, archive, drafts
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: "Задачи"
        case .archive: "Архив"
        case .drafts: "Черновики"
        }
    }

    /// Folder inside the project's `tasks/`.
    public func url(in tasks: URL) -> URL {
        self == .active ? tasks : tasks.appendingPathComponent(rawValue, isDirectory: true)
    }

    /// Folder of a task file, by its path.
    public init(of file: URL) {
        let dir = file.deletingLastPathComponent()
        let parked = TaskFolder(rawValue: dir.lastPathComponent)
        if let parked, parked != .active, dir.deletingLastPathComponent().lastPathComponent == "tasks" {
            self = parked
        } else {
            self = .active
        }
    }
}

extension TaskItem {
    public var folder: TaskFolder { TaskFolder(of: url) }
    /// Counts as done for tasks that depend on it: a draft never does.
    public var satisfiesDepends: Bool { status == .done && folder != .drafts }
}

extension Project {
    public subscript(folder: TaskFolder) -> [TaskItem] {
        get {
            switch folder {
            case .active: tasks
            case .archive: archive
            case .drafts: drafts
            }
        }
        set {
            switch folder {
            case .active: tasks = newValue
            case .archive: archive = newValue
            case .drafts: drafts = newValue
            }
        }
    }

    /// Active tasks first: on a name clash the active one is meant.
    public var allTasks: [TaskItem] { tasks + drafts + archive }

    /// Nodes for `DependencyPlan`: active tasks plus archive and drafts as places `depends:` may point to.
    public var dependencyNodes: [String: DependencyPlan.Node] {
        Dictionary(allTasks.map {
            ($0.fileName, DependencyPlan.Node(done: $0.satisfiesDepends, depends: $0.depends,
                                              parked: $0.folder == .active ? nil : $0.folder))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The task by path, or — after it was moved between the folders — by the file name.
    public func task(path: String) -> TaskItem? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return allTasks.first { $0.id == path } ?? allTasks.first { $0.fileName == name }
    }
}

extension TaskFile {
    /// Text of any error of reading, moving or writing task files.
    public static func message(_ error: Error) -> String { CLIError(error).message }

    /// Moves a task file to another folder of its `tasks/` under the same name. Bytes stay as they are;
    /// a taken name fails with `.exists` and nothing is overwritten.
    @discardableResult
    public static func move(_ file: URL, to folder: TaskFolder) throws -> URL {
        let from = TaskFolder(of: file)
        let dir = file.deletingLastPathComponent()
        let tasks = from == .active ? dir : dir.deletingLastPathComponent()
        let target = folder.url(in: tasks).appendingPathComponent(file.lastPathComponent)
        guard from != folder else { return file }
        do { try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw Failure.io(error.localizedDescription) }
        return try locked(dir) {
            guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw Failure.exists(target.lastPathComponent) }
                throw Failure.io(String(cString: strerror(errno)))
            }
            return target
        }
    }
}
