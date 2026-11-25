import Foundation

/// Files in a folder somebody else writes to: no symlink on the way is followed, only regular files, size is limited.
public struct SafeFolder {
    public struct Failure: LocalizedError, Equatable {
        public let path: String
        public let why: String
        public var errorDescription: String? { "\(path): \(why)" }
        /// The file isn't there (as opposed to being something suspicious).
        public var missing: Bool { why == Self.noFile }
        static let noFile = "нет файла"
    }

    let root: URL
    public init(_ root: URL) { self.root = root }

    private func fail(_ path: String) -> Failure {
        Failure(path: path, why: errno == ENOENT ? Failure.noFile : String(cString: strerror(errno)))
    }

    /// Descriptor of the folder that holds `path`, and the file's name in it. The caller closes it.
    private func parent(_ path: String, create: Bool) throws -> (Int32, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { ["", ".", ".."].contains($0) }) else { throw Failure(path: path, why: "недопустимый путь") }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw fail(path) }
        for p in parts.dropLast() {
            if create { mkdirat(fd, p, 0o755) }
            let next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = fail(path)
            close(fd)
            guard next >= 0 else { throw error }
            fd = next
        }
        return (fd, parts[parts.count - 1])
    }

    public func read(_ path: String, limit: Int) throws -> Data {
        let (dir, name) = try parent(path, create: false)
        defer { close(dir) }
        // O_NONBLOCK: a FIFO must not hang us.
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fail(path) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Failure(path: path, why: "не обычный файл") }
        // The size may grow while it is read.
        let d = try h.read(upToCount: limit + 1) ?? Data()
        guard d.count <= limit else { throw Failure(path: path, why: "больше \(limit) байт") }
        return d
    }

    /// Replaces the file itself, not what a symlink in its place points to.
    public func write(_ data: Data, to path: String) throws {
        let (dir, name) = try parent(path, create: true)
        defer { close(dir) }
        let temp = ".tt-" + UUID().uuidString
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw fail(path) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try h.write(contentsOf: data)
            try h.close()
            guard renameat(dir, temp, dir, name) == 0 else { throw fail(path) }
        } catch {
            unlinkat(dir, temp, 0)
            throw error
        }
    }
}

extension SafeFolder {
    public func remove(_ path: String) throws {
        let (dir, name) = try parent(path, create: false)
        defer { close(dir) }
        guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else { throw fail(path) }
    }
}

/// Tracker files of a container job: copied into the worktree before a turn; after it only the job's own task comes back.
public struct DockerExchange: Sendable {
    static let limit = 1 << 20

    public enum Outcome: Equatable, Sendable {
        case unchanged, updated
        /// The original changed meanwhile: it stays, the agent's version is kept here.
        case conflict(URL)
    }

    public let main: URL
    public let worktree: URL
    /// Relative to the project folder, e.g. `tasks/20261123-142040-docker.md`.
    public let task: String
    /// The task as it was given to the agent.
    public let given: Data
    /// What was in the worktree under these paths; nil = nothing.
    let before: [String: Data?]

    /// Paths of the files as the agent sees them are under `ContainerSpec.workspace`.
    public static func begin(main: URL, worktree: URL, taskFile: String, extra: [String: Data] = [:]) throws -> DockerExchange {
        let dst = SafeFolder(worktree), task = "tasks/" + taskFile
        let given = try SafeFolder(main).read(task, limit: limit)
        var before: [String: Data?] = [:]
        func put(_ data: Data, _ path: String) throws {
            // Not a regular file (a link the agent left): replaced, and removed at the end.
            before[path] = .some(try? dst.read(path, limit: limit))
            try dst.write(data, to: path)
        }
        do {
            try put(given, task)
            for (path, data) in extra { try put(data, path) }
            for name in ["about.md", "spectrack.md"] {
                do { try put(try SafeFolder(main).read(name, limit: limit), name) }
                catch let e as SafeFolder.Failure where e.missing { continue }
            }
        } catch {
            DockerExchange(main: main, worktree: worktree, task: task, given: given, before: before).restore()
            throw error
        }
        return DockerExchange(main: main, worktree: worktree, task: task, given: given, before: before)
    }

    /// The worktree's own copies come back, so a merge of main into the branch doesn't meet changed tracker files.
    public func restore() {
        let dst = SafeFolder(worktree)
        for (path, data) in before {
            if let data { try? dst.write(data, to: path) } else { try? dst.remove(path) }
        }
    }

    /// `conflicts`: folder in the app's data.
    public func finish(conflicts: URL) throws -> Outcome {
        let new = try SafeFolder(worktree).read(task, limit: Self.limit)
        guard new != given else { return .unchanged }
        guard let text = String(data: new, encoding: .utf8), Frontmatter.parse(text).fields["status"] != nil else {
            throw SafeFolder.Failure(path: task, why: "агент испортил файл задачи")
        }
        let folder = main.appendingPathComponent(task).deletingLastPathComponent()
        // The folder itself is gone: nothing to lock, `now` below is nil.
        guard FileManager.default.fileExists(atPath: folder.path) else { return try settle(new, conflicts) }
        return try TaskFile.locked(folder) { try settle(new, conflicts) }
    }

    private func settle(_ new: Data, _ conflicts: URL) throws -> Outcome {
        // Deleted or moved to the archive meanwhile is a change too: the task must not reappear.
        let now = try? SafeFolder(main).read(task, limit: Self.limit)
        guard now == given else {
            if now == new { return .unchanged }
            try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
            let u = conflicts.appendingPathComponent(UUID().uuidString + "-" + (task as NSString).lastPathComponent)
            try new.write(to: u)
            return .conflict(u)
        }
        // `tt` and the app wait for the lock; only a writer without it fits between the read above and this rename.
        try SafeFolder(main).write(new, to: task)
        return .updated
    }
}
