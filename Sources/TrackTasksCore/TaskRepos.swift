import Darwin
import Foundation

/// Frontmatter `repos:` — other repositories the task changes besides its own project's one.
/// Paths are relative to the projects root (or absolute) and must lead inside it.
public enum TaskRepos {
    public struct Failure: LocalizedError, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The form of an entry, without looking at the disk.
    public static func isValid(_ path: String) -> Bool {
        !path.isEmpty && path == path.trimmingCharacters(in: .whitespaces) && !path.hasPrefix("~")
            && !path.contains { "*\\,\"#".contains($0) || $0.isNewline || $0 == "\0" }
    }

    /// Folders of the repositories, symlinks resolved, or the first reason not to touch them.
    /// Asked again right before worktrees are made: a symlink may have been changed meanwhile.
    public static func resolve(_ entries: [String], root: URL, project: URL) -> Result<[URL], Failure> {
        guard !entries.isEmpty else { return .success([]) }
        guard let rootID = fileID(canonical(root)) else { return .failure(.init("repos: нет корня проектов \(root.path)")) }
        let home = URL(fileURLWithPath: canonical(project))
        // One text for both: an agent must not learn from it what exists elsewhere on the disk.
        let outside = "нет такой папки внутри корня проектов \(root.path)"
        var out: [URL] = [], taken: [FileID] = []
        for e in entries {
            func bad(_ why: String) -> Result<[URL], Failure> { .failure(.init("repos: \(e) — \(why)")) }
            guard isValid(e) else { return bad("нужен путь папки без «~», «*», кавычек и «#»") }
            let full = e.hasPrefix("/") ? e : root.path + "/" + e
            guard let real = realPath(full), let id = fileID(real) else { return bad(outside) }
            let url = URL(fileURLWithPath: real, isDirectory: true)
            if id == rootID { return bad("это сам корень проектов") }
            let above = ancestors(url)
            // By the folders themselves, not by text: neither letter case nor a common prefix can deceive it.
            guard above.contains(rootID) else { return bad(outside) }
            guard isRepository(url) else { return bad("не верхняя папка git-репозитория") }
            if let top = topFolder(home), fileID(top.path) == id { return bad("это репозиторий самого проекта") }
            if fileID(home.path).map(above.contains) == true || ancestors(home).contains(id) { return bad("вложен в папку проекта или содержит её") }
            if taken.contains(id) { return bad("указан дважды") }
            for other in out where ancestors(other).contains(id) || fileID(other.path).map(above.contains) == true {
                return bad("вложен в другой репозиторий списка или содержит его")
            }
            taken.append(id)
            out.append(url)
        }
        return .success(out)
    }

    /// Problems that need the projects root; the form is checked by `TaskLint.fileProblems`.
    public static func lint(_ p: inout Project, root: URL) {
        func add(_ tasks: inout [TaskItem]) {
            for i in tasks.indices where !tasks[i].repos.isEmpty && tasks[i].repos.allSatisfy(isValid) {
                guard case .failure(let f) = resolve(tasks[i].repos, root: root, project: p.url) else { continue }
                tasks[i].problems.append(TaskProblem(.badRepo, f.message))
            }
        }
        var tasks = p.tasks, drafts = p.drafts
        add(&tasks)
        add(&drafts)
        p.tasks = tasks
        p.drafts = drafts
    }

    /// Path as the disk names it: symlinks resolved, real letter case. The path itself when it doesn't exist.
    public static func canonical(_ url: URL) -> String { realPath(url.path) ?? url.standardizedFileURL.path }

    // MARK: Disk

    private struct FileID: Equatable {
        var device: Int32
        var inode: UInt64
    }

    private static func fileID(_ path: String) -> FileID? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileID(device: st.st_dev, inode: UInt64(st.st_ino))
    }

    private static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        let s = String(cString: r)
        // `realpath` keeps the letter case of the request.
        let c = try? URL(fileURLWithPath: s).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        return c ?? s
    }

    /// Folders above this one, itself not included.
    private static func ancestors(_ url: URL) -> [FileID] {
        var out: [FileID] = [], u = url.deletingLastPathComponent()
        while true {
            if let id = fileID(u.path) { out.append(id) }
            if u.path == "/" || u.path.isEmpty { return out }
            u = u.deletingLastPathComponent()
        }
    }

    /// An own `.git` folder: a linked worktree or a submodule has a file there and belongs to another repository.
    private static func isRepository(_ url: URL) -> Bool {
        var st = stat()
        let git = url.appendingPathComponent(".git").path
        return lstat(git, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            && FileManager.default.fileExists(atPath: git + "/HEAD")
    }

    /// Top folder of the repository the project is in.
    private static func topFolder(_ url: URL) -> URL? {
        var u = url
        while u.path != "/" && !u.path.isEmpty {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }
}
