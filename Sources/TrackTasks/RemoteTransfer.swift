import Foundation
import TrackTasksCore

/// Code and the task file between a local worktree and a server. Synchronous — not for the main thread.
enum RemoteTransfer {
    struct Snapshot: Equatable { var commit: String, tree: String }

    enum Applied: Equatable { case applied, already, nothing }

    /// The worktree was changed while the server worked; the result waits in `ref`.
    struct Changed: LocalizedError {
        let ref: String, detail: String
        var errorDescription: String? { "Результат с сервера не наложен: \(detail). Он сохранён в \(ref)" }
    }
    /// The result has something it must not have.
    struct Refused: LocalizedError {
        let detail: String
        var errorDescription: String? { "Результат с сервера не принят: \(detail)" }
    }

    // MARK: git

    /// No hooks and no fsmonitor: the code isn't trusted.
    private static let config = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.safecrlf=false"]

    private static func git(_ args: [String], _ dir: URL, env: [String: String] = [:], input: Data? = nil) -> DiffReject.Output {
        DiffLoader.runEnv(config + args, in: dir, env: env, input: input)
    }

    @discardableResult
    private static func ok(_ args: [String], _ dir: URL, env: [String: String] = [:], input: Data? = nil) throws -> DiffReject.Output {
        let o = git(args, dir, env: env, input: input)
        guard o.ok else {
            let e = o.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError.failed(e.isEmpty ? "git завершился с ошибкой" : e)
        }
        return o
    }

    private static func line(_ args: [String], _ dir: URL, env: [String: String] = [:]) throws -> String {
        try ok(args, dir, env: env).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func list(_ args: [String], _ dir: URL, env: [String: String] = [:]) throws -> [String] {
        try ok(args, dir, env: env).out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    static func baseRef(_ run: String) -> String { "refs/tracktasks/remote/\(run)/base" }
    static func resultRef(_ run: String) -> String { "refs/tracktasks/remote/\(run)/result" }
    private static func serverRef(_ run: String) -> String { "refs/tt/result/\(run)" }

    static func dropRefs(_ run: String, in dir: URL) {
        for r in [baseRef(run), resultRef(run)] { _ = git(["update-ref", "-d", r], dir) }
    }

    // MARK: There

    private static let secrets: Set<String> = [".env", ".env.local", ".env.development"]

    /// Repositories a bundle can't carry over whole.
    static func check(_ dir: URL) throws {
        guard git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], dir).ok else {
            throw RemoteError.failed("Нужен git-репозиторий с коммитом")
        }
        if try line(["rev-parse", "--is-shallow-repository"], dir) == "true" { throw RemoteError.failed("Неполный (shallow) клон на сервер не переносится") }
        if git(["config", "--get-regexp", #"^remote\..*\.promisor$"#], dir).ok { throw RemoteError.failed("Частичный (partial) клон на сервер не переносится") }
        for e in try list(["ls-tree", "-r", "-z", "--full-tree", "HEAD"], dir) {
            let path = e.drop { $0 != "\t" }.dropFirst()
            if e.hasPrefix("160000") { throw RemoteError.failed("Submodule на сервер не переносится: \(path)") }
            if let n = path.split(separator: "/").last, secrets.contains(String(n)) {
                throw RemoteError.failed("В git закоммичен \(path): на сервер такие файлы не отправляются")
            }
        }
        let lfs = git(["grep", "-q", "filter=lfs", "HEAD", "--", ":(top,glob)**/.gitattributes"], dir)
        if lfs.ok { throw RemoteError.failed("Файлы Git LFS на сервер не переносятся") }
    }

    /// Temporary index with the state of the folder. The real one stays as it is.
    /// Own worktree: everything git doesn't ignore. Main folder: only tracked files.
    private static func withIndex<T>(_ dir: URL, untracked: Bool, _ body: ([String: String]) throws -> T) throws -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tracktasks-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("index")
        let real = try line(["rev-parse", "--path-format=absolute", "--git-path", "index"], dir)
        if FileManager.default.fileExists(atPath: real) { try FileManager.default.copyItem(atPath: real, toPath: copy.path) }
        let env = ["GIT_INDEX_FILE": copy.path]
        // Same rules as the commit of the job: no tracker files, no linked dependencies.
        var spec = Array(WorktreeGit.stage(excluding: Worktrees.links(of: dir)).dropFirst(2))
        spec += secrets.sorted().map { ":(exclude,glob)**/\($0)" }
        // Nested repositories.
        let others = untracked ? try list(["ls-files", "--others", "--exclude-standard", "-z"], dir, env: env) : []
        spec += others.filter { $0.hasSuffix("/") }.map { ":(exclude,top,literal)" + $0.dropLast() }
        try ok(["add", untracked ? "-A" : "-u"] + spec, dir, env: env)
        return try body(env)
    }

    static func tree(_ dir: URL, untracked: Bool = true) throws -> String {
        try withIndex(dir, untracked: untracked) { try line(["write-tree"], dir, env: $0) }
    }

    /// Commit with the state of the folder on top of HEAD, kept by a ref of the run.
    static func snapshot(_ dir: URL, run: String, untracked: Bool) throws -> Snapshot {
        let t = try tree(dir, untracked: untracked)
        // The run id makes the commit new: an empty bundle is an error.
        let o = try ok(["-c", "user.name=TrackTasks", "-c", "user.email=tracktasks@localhost", "commit-tree", t, "-p", "HEAD"],
                       dir, input: Data("TrackTasks remote \(run)\n".utf8))
        let c = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try ok(["update-ref", baseRef(run), c], dir)
        return Snapshot(commit: c, tree: t)
    }

    /// `known`: what the server says it has.
    static func bundle(_ dir: URL, run: String, known: [String], to file: URL) throws {
        let ids = Set(known.filter { RemoteRunIDs.isOID($0) })
        var have: [String] = []
        if !ids.isEmpty {
            let o = git(["cat-file", "--batch-check=%(objectname) %(objecttype)"], dir, input: Data(ids.sorted().joined(separator: "\n").utf8 + [10]))
            have = o.text.split(separator: "\n").filter { $0.hasSuffix(" commit") }.map { "^" + $0.split(separator: " ")[0] }
        }
        try ok(["bundle", "create", "-q", file.path, baseRef(run)] + have, dir)
    }

    // MARK: Back

    /// Reads the bundle into a ref of its own. Objects are checked.
    static func fetch(_ dir: URL, run: String, bundle: URL, base: String) throws -> String {
        try ok(["bundle", "verify", "-q", bundle.path], dir)
        try ok(["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true", "fetch", "-q", "--no-tags", "--no-write-fetch-head",
                "--no-recurse-submodules", "--no-auto-maintenance", bundle.path, "+\(serverRef(run)):\(resultRef(run))"], dir)
        let r = try line(["rev-parse", "--verify", resultRef(run) + "^{commit}"], dir)
        guard try line(["rev-parse", r + "^@"], dir) == base else { throw Refused(detail: "он сделан не от отправленного кода") }
        return r
    }

    /// Puts the result onto the worktree as uncommitted changes; the commit is made by the queue.
    static func apply(_ dir: URL, run: String, base: Snapshot, result: String) throws -> Applied {
        let want = try line(["rev-parse", result + "^{tree}"], dir)
        if want == base.tree { return .nothing }
        let raw = try list(["diff-tree", "-r", "-z", "--no-renames", "--raw", "--no-commit-id", base.commit, result], dir)
        var added: [String] = []
        // «:oldmode newmode old new STATUS», then the path.
        for i in stride(from: 0, to: raw.count - 1, by: 2) {
            let f = raw[i].split(separator: " "), path = raw[i + 1]
            guard f.count == 5 else { throw Refused(detail: "непонятный список файлов") }
            if f[1] == "160000" { throw Refused(detail: "вложенный репозиторий \(path)") }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.contains(where: { $0.lowercased() == ".git" || $0 == ".." || $0.isEmpty }) { throw Refused(detail: "путь \(path)") }
            if Worktrees.links(of: dir).contains(where: { l in let lp = l.lowercased(), pl = path.lowercased(); return pl == lp || pl.hasPrefix(lp + "/") }) { throw Refused(detail: "путь \(path) связан с основной папкой") }
            let low = path.lowercased()
            if DirtyFiles.isTrackerFile(low) { throw Refused(detail: "файл трекера \(path)") }
            if f[4] == "A" { added.append(path) }
        }
        return try withIndex(dir, untracked: true) { env in
            let now = try line(["write-tree"], dir, env: env)
            if now == want { return .already }
            let ref = resultRef(run)
            guard now == base.tree else { throw Changed(ref: ref, detail: "worktree изменился за время запуска") }
            for p in added {
                // An ignored file of the user, or a link that leads out of the worktree.
                var at = dir.path
                for part in p.split(separator: "/") {
                    at += "/" + part
                    var st = stat()
                    guard lstat(at, &st) == 0 else { break }
                    if at == dir.path + "/" + p || st.st_mode & S_IFMT == S_IFLNK {
                        // A tracked path that the result replaces is git's own business.
                        let rel = String(at.dropFirst(dir.path.count + 1))
                        if git(["ls-files", "--error-unmatch", "--", ":(literal)" + rel], dir, env: env).ok { break }
                        throw Changed(ref: ref, detail: "на месте \(p) уже есть файл, которого git не видит")
                    }
                }
            }
            let r = git(["read-tree", "-m", "-u", base.commit, result], dir, env: env)
            guard r.ok else { throw Changed(ref: ref, detail: r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .applied
        }
    }

    // MARK: Task file

    enum TaskResult: Equatable {
        case same, replaced, merged
        /// The local file stays; the server's one is here.
        case conflict(URL)
    }

    /// `base` — as it was sent, `remote` — as it came back.
    static func returnTask(_ task: URL, base: URL, remote: URL) throws -> TaskResult {
        for _ in 0..<3 {
            guard let new = try? Data(contentsOf: remote), String(data: new, encoding: .utf8) != nil, !new.isEmpty,
                  let old = try? Data(contentsOf: base), let local = try? TaskFile(reading: task) else { return .conflict(remote) }
            if new == old || new == local.data { return .same }
            var merged = new
            if local.data != old {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                let mine = remote.deletingLastPathComponent().appendingPathComponent("task-local.md")
                try local.data.write(to: mine)
                p.arguments = ["merge-file", "-p", mine.path, base.path, remote.path]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                try p.run()
                merged = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { return .conflict(remote) }
            }
            do {
                try local.write(String(decoding: merged, as: UTF8.self))
                return local.data == old ? .replaced : .merged
            } catch TaskFile.Failure.changed { continue }
        }
        return .conflict(remote)
    }
}

private enum RemoteRunIDs {
    static func isOID(_ s: String) -> Bool { s.range(of: #"\A([0-9a-f]{40}|[0-9a-f]{64})\z"#, options: .regularExpression) != nil }
}
