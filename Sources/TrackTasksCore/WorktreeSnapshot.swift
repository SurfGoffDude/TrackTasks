import Foundation

/// Everything git can keep of a worktree before it is deleted: commits, index and files, under its own ref — outside
/// the checkpoints, which go away with the branch. Ignored files aren't kept, only listed.
/// Refuses instead of keeping a part. Blocks: not for the main thread.
public enum WorktreeSnapshot {
    public typealias Failure = Checkpoints.Failure
    public typealias Site = Checkpoints.Site
    public typealias Runner = Checkpoints.Runner

    public struct Saved: Codable, Equatable, Sendable {
        public var ref: String
        /// Tree = files; parents = HEAD and `index`.
        public var oid: String
        public var index: String
        public var head: String
        public init(ref: String, oid: String, index: String, head: String) {
            self.ref = ref; self.oid = oid; self.index = index; self.head = head
        }
    }

    public static let prefix = "refs/tracktasks/removed/"

    // MARK: Saving

    public static func create(_ s: Site, id: String, number: Int, git: Runner) throws -> Saved {
        try refuse(s, git)
        let head = try Checkpoints.text(["rev-parse", "--verify", "HEAD^{commit}"], s.folder, [:], git)
        let (index, files) = try trees(s, git)
        let i = try commit(index, parents: [head], "TrackTasks: индекс удалённого worktree", s.folder, git)
        let c = try commit(files, parents: [head, i], "TrackTasks: удалённый worktree \(s.branch)", s.folder, git)
        let saved = Saved(ref: "\(prefix)\(id)/\(number)", oid: c, index: i, head: head)
        // An empty old value: the ref must not exist.
        try Checkpoints.ok(["update-ref", saved.ref, c, ""], s.folder, [:], nil, git)
        do { try verify(saved, in: s.folder, git: git) } catch {
            try? delete(saved, in: s.folder, git: git)
            throw error
        }
        return saved
    }

    /// The ref is there and every object it needs can be found.
    public static func verify(_ x: Saved, in dir: URL, git: Runner) throws {
        guard try Checkpoints.text(["rev-parse", "--verify", x.ref], dir, [:], git) == x.oid else { throw Failure("Снимок не читается") }
        try Checkpoints.ok(["rev-list", "--objects", "--quiet", x.oid, "--not", x.head], dir, [:], nil, git)
    }

    /// The worktree is still what the snapshot has.
    public static func matches(_ s: Site, _ x: Saved, git: Runner) throws -> Bool {
        try refuse(s, git)
        guard try Checkpoints.text(["rev-parse", "--verify", "HEAD^{commit}"], s.folder, [:], git) == x.head else { return false }
        let (index, files) = try trees(s, git)
        return try index == tree(x.index, s.folder, git) && files == tree(x.oid, s.folder, git)
    }

    public static func delete(_ x: Saved, in dir: URL, git: Runner) throws {
        // Already gone.
        guard Checkpoints.run(["rev-parse", "-q", "--verify", x.ref], dir, [:], nil, git).ok else {
            try Checkpoints.ok(["rev-parse", "--git-dir"], dir, [:], nil, git)
            return
        }
        try Checkpoints.ok(["update-ref", "-d", x.ref, x.oid], dir, [:], nil, git)
    }

    /// Ignored files and folders (with «/» at the end), without links the tracker put there.
    public static func ignored(_ s: Site, git: Runner) throws -> [String] {
        try Checkpoints.paths(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], s.folder, [:], git)
            .filter { !(s.links.contains($0) && Checkpoints.isLink(s.folder.appendingPathComponent($0).path)) }
    }

    /// Changed and new files that only the snapshot will have.
    public static func uncommitted(_ s: Site, git: Runner) throws -> [String] {
        let changed = try Checkpoints.paths(["diff", "--name-only", "--no-renames", "--no-ext-diff", "-z", "HEAD"], s.folder, ["GIT_OPTIONAL_LOCKS": "0"], git)
        let new = try Checkpoints.paths(["ls-files", "--others", "--exclude-standard", "-z"], s.folder, [:], git).filter { !s.links.contains($0) }
        return Set(changed + new).sorted()
    }

    private static func trees(_ s: Site, _ git: Runner) throws -> (index: String, files: String) {
        try Checkpoints.withIndex(s, git) { env in
            let index = try Checkpoints.text(["write-tree"], s.folder, env, git)
            try Checkpoints.stage(s, env, git)
            return (index, try Checkpoints.text(["write-tree"], s.folder, env, git))
        }
    }

    private static func tree(_ commit: String, _ dir: URL, _ git: Runner) throws -> String {
        try Checkpoints.text(["rev-parse", "\(commit)^{tree}"], dir, [:], git)
    }

    private static func commit(_ tree: String, parents: [String], _ message: String, _ dir: URL, _ git: Runner) throws -> String {
        let o = try Checkpoints.ok(["-c", "user.name=TrackTasks", "-c", "user.email=tracktasks@localhost", "-c", "commit.gpgSign=false", "-c", "i18n.commitEncoding=UTF-8",
                                    "commit-tree", tree] + parents.flatMap { ["-p", $0] }, dir, [:], Data((message + "\n").utf8), git)
        return Checkpoints.trim(o)
    }

    /// What a snapshot can't hold.
    private static func refuse(_ s: Site, _ git: Runner) throws {
        try Checkpoints.check(s, git)
        if !(try Checkpoints.paths(["ls-files", "-u", "-z"], s.folder, [:], git)).isEmpty { throw Failure("В индексе неразрешённые конфликты") }
        for line in try Checkpoints.paths(["ls-files", "-v", "-z"], s.folder, [:], git) {
            if let c = line.first, c == "S" || c.isLowercase {
                throw Failure("Файл \(line.dropFirst(2)) скрыт от git (skip-worktree или assume-unchanged)")
            }
        }
        for line in try Checkpoints.paths(["ls-files", "-s", "-z"], s.folder, [:], git) where line.hasPrefix("160000 ") {
            let p = String(line.drop { $0 != "\t" }.dropFirst())
            // Its own commits would go away with the worktree.
            if let inside = try? FileManager.default.contentsOfDirectory(atPath: s.folder.appendingPathComponent(p).path), !inside.isEmpty {
                throw Failure("В подмодуле \(p) есть файлы")
            }
        }
        let skip = Set(try Checkpoints.paths(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], s.folder, [:], git)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        try walk(s.folder, "", skip)
    }

    /// git skips special files and nested repositories silently.
    private static func walk(_ dir: URL, _ at: String, _ skip: Set<String>) throws {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
            throw Failure("Не читается папка \(at.isEmpty ? "worktree" : at)")
        }
        for n in names {
            let p = at.isEmpty ? n : at + "/" + n
            if n.lowercased() == ".git" {
                if at.isEmpty { continue }
                throw Failure("Внутри вложенный репозиторий: \(at)")
            }
            let url = dir.appendingPathComponent(n)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw Failure("Не читается \(p)") }
            if skip.contains(p) || skip.contains(p.precomposedStringWithCanonicalMapping) { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: try walk(url, p, skip)
            case S_IFREG, S_IFLNK: break
            default: throw Failure("Особый файл: \(p)")
            }
        }
    }

    // MARK: Restoring

    /// A new worktree from the snapshot. The folder and the branch must not exist. On an error nothing is left.
    /// `prepared` runs when the folder exists but has no files yet.
    public static func restore(_ x: Saved, main: URL, to folder: URL, branch: String, git: Runner, prepared: () throws -> Void = {}) throws {
        guard !exists(folder) else { throw Failure("Папка \(folder.lastPathComponent) уже есть") }
        guard try !branchExists(branch, in: main, git: git) else { throw Failure("Ветка \(branch) уже есть") }
        try verify(x, in: main, git: git)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Checkpoints.ok(["worktree", "add", "--no-checkout", "-b", branch, folder.path, x.head], main, [:], nil, git)
            try prepared()
            try Checkpoints.ok(["read-tree", "--reset", "-u", x.oid], folder, [:], nil, git)
            try Checkpoints.ok(["read-tree", "--reset", x.index], folder, [:], nil, git)
            // Non-zero while files differ from the index.
            _ = Checkpoints.run(["update-index", "-q", "--refresh"], folder, [:], nil, git)
        } catch {
            undo(x, main: main, folder: folder, branch: branch, git: git)
            throw error
        }
    }

    /// Takes back a just made `restore`.
    public static func undo(_ x: Saved, main: URL, folder: URL, branch: String, git: Runner) {
        _ = Checkpoints.run(["worktree", "remove", "--force", folder.path], main, [:], nil, git)
        if exists(folder) {
            try? FileManager.default.removeItem(at: folder)
            _ = Checkpoints.run(["worktree", "remove", "--force", folder.path], main, [:], nil, git)
        }
        _ = Checkpoints.run(["update-ref", "-d", "refs/heads/\(branch)", x.head], main, [:], nil, git)
    }

    public static func exists(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0
    }

    public static func branchExists(_ branch: String, in dir: URL, git: Runner) throws -> Bool {
        let o = Checkpoints.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], dir, [:], nil, git)
        guard o.status == 0 || o.status == 1 else { throw Checkpoints.failure(o) }
        return o.ok
    }
}
