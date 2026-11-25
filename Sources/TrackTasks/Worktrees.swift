import Foundation
import TrackTasksCore

/// Isolated checkouts for running several code jobs in one project at the same time.
/// Each job gets `~/Library/Application Support/TrackTasks/worktrees/<project>/<id>` on branch `tracktasks/<slug>-<id>`.
enum Worktrees {
    static let enabledKey = "worktreesEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Info: Identifiable, Hashable, Codable {
        var id: String { path.path }
        let path: URL
        let main: URL
        let branch: String
    }

    struct Result {
        let ok: Bool
        let out: String
        let err: String
        var message: String { (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/worktrees", isDirectory: true)
    }

    /// git with stdout + stderr.
    @discardableResult
    static func git(_ args: [String], in url: URL) -> Result {
        if let why = ContainerStore.shared.refusal(url) { return Result(ok: false, out: "", err: why) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path] + ContainerStore.shared.gitOptions(url) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        Log.git.process("git", project: url.lastPathComponent, command: args.joined(separator: " "))
        do { try p.run() } catch { return Result(ok: false, out: "", err: error.localizedDescription) }
        // Read both pipes concurrently so a chatty stderr can't block the process.
        nonisolated(unsafe) var errData = Data()
        let g = DispatchGroup()
        OwnThread.start(group: g) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return Result(ok: p.terminationStatus == 0,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// New worktree from the project's current HEAD. Returns nil if the project isn't a git repo with commits.
    /// `container`: marked for docker; links to the main folder would lead nowhere there.
    /// `from`: branch or commit to start from instead of HEAD (a fork of a job branches off the source's branch).
    static func create(for project: URL, title: String, jobID: UUID, from ref: String? = nil, root: URL = Worktrees.root, container: Bool = false) -> (Info, base: String)? {
        try? make(for: project, title: title, jobID: jobID, from: ref, root: root, container: container).get()
    }

    /// The same with the reason of a failure.
    static func make(for project: URL, title: String, jobID: UUID, from ref: String? = nil, root: URL = Worktrees.root, container: Bool = false)
        -> Swift.Result<(Info, base: String), TaskRepos.Failure> {
        guard Git.isRepo(project) else { return .failure(.init("нет git")) }
        let head = git(["rev-parse", "--verify", "\(ref ?? "HEAD")^{commit}"], in: project)
        guard head.ok else { return .failure(.init("нет коммитов")) }
        let base = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(jobID.uuidString.prefix(6)).lowercased()
        let slug = Codec.slug(title).prefix(28)
        let branch = "tracktasks/\(slug.isEmpty ? "task" : String(slug))-\(short)"
        let key = project.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "__")
        let path = root.appendingPathComponent(key).appendingPathComponent(short)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let added = git(WorktreeGit.add(branch: branch, path: path.path, base: base), in: project)
        guard added.ok else { return .failure(.init(added.message)) }
        let info = Info(path: path, main: project, branch: branch)
        if container {
            do { try ContainerStore.shared.mark(info) } catch {
                remove(info, deleteBranch: true, force: true)
                return .failure(.init(error.localizedDescription))
            }
        } else {
            linkDependencies(from: project, to: path)
            putProjectFiles(from: project, to: path)
        }
        return .success((info, base))
    }

    /// Ignored folders/files that builds need (deps, env) — symlinked from the main folder, never committed.
    static let linked = WorktreeFiles.builtin

    /// Names kept out of commit, diff, checkpoints, merge and PR checks of this worktree.
    /// Old worktrees and containers have only the fixed set.
    static func links(of folder: URL) -> [String] { WorktreeFiles.links(of: folder) }

    /// Warnings of the last preparation of this worktree (for the job log).
    static func fileWarnings(of folder: URL) -> [String] { WorktreeFiles.manifest(of: folder)?.warnings ?? [] }

    /// `.worktreeinclude` copies and `shared:` links. Not for containers.
    static func putProjectFiles(from main: URL, to wt: URL) {
        let plan = WorktreeFiles.plan(project: main, git: { args, dir in
            let r = git(args, in: dir)
            return (r.ok, r.out)
        })
        guard !plan.isEmpty else { return }
        WorktreeFiles.write(WorktreeFiles.apply(plan, from: main, to: wt), to: wt)
    }

    static func linkDependencies(from main: URL, to wt: URL) {
        let fm = FileManager.default
        for name in linked {
            let src = main.appendingPathComponent(name), dst = wt.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            // Only link what git ignores — tracked files are already in the worktree.
            guard git(["check-ignore", "-q", name], in: main).ok else { continue }
            try? fm.createSymbolicLink(at: dst, withDestinationURL: src)
        }
    }

    /// Commit everything the job changed in its worktree (tracker files excluded — they live in the main folder).
    static func commitAll(_ w: Info, message: String) -> Result {
        git(WorktreeGit.stage(excluding: links(of: w.path)), in: w.path)
        let staged = git(["diff", "--cached", "--quiet"], in: w.path)
        if staged.ok { return Result(ok: true, out: "nothing", err: "") }
        return git(["commit", "--no-verify", "-m", message], in: w.path)
    }

    static func diffStat(_ w: Info, base: String) -> String {
        git(["diff", "--shortstat", "\(base)..\(w.branch)"], in: w.main).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uncommitted code changes in the main folder (tracker files excluded). Empty when clean or not a repo.
    static func hasCommits(_ project: URL) -> Bool {
        git(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: project).ok
    }

    /// `projectRelative`: paths inside the project folder lose its prefix when the project is a subfolder of the
    /// repository (git status prints paths from the repository root), like paths in `files:`.
    static func dirtyFiles(in project: URL, projectRelative: Bool = false) -> [String] {
        Log.git.measure("Worktrees.dirtyFiles", project.lastPathComponent) {
            let r = git(["status", "--porcelain", "-z", "-uall"], in: project)
            guard r.ok else { return [] }
            var paths = DirtyFiles.parsePorcelainZ(r.out)
            if projectRelative {
                let prefix = git(["rev-parse", "--show-prefix"], in: project).out.trimmingCharacters(in: .newlines)
                if !prefix.isEmpty { paths = paths.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 } }
            }
            return DirtyFiles.significant(paths)
        }
    }

    /// `teardown`: command allowed for this removal only (see `JobQueue.dangerTeardown`).
    /// `scripts: false` — no teardown: the worktree of an extra repository had no setup either.
    static func remove(_ w: Info, deleteBranch: Bool, force: Bool, teardown: String? = nil, scripts: Bool = true) {
        DevServers.stopAndWait(folder: w.path)
        let container = ContainerStore.shared.isContainer(w.path)
        if container {
            // A container that is still there may write: the folder waits for it.
            if let why = ContainerStore.shared.release(w.path) { return keepFolder(w, why) }
        }
        if scripts { ScriptStore.teardown(w, allowed: teardown) }
        // Teardown has a container of its own.
        if container, let why = ContainerStore.shared.release(w.path) { return keepFolder(w, why) }
        git(["worktree", "remove", "--force", w.path.path], in: w.main)
        if FileManager.default.fileExists(atPath: w.path.path) {
            try? FileManager.default.removeItem(at: w.path)
            git(["worktree", "prune"], in: w.main)
        }
        if !FileManager.default.fileExists(atPath: w.path.path) { ContainerStore.shared.forget(w.path) }
        RemoteCleanup.shared.release(folder: w.path)
        Checkpoints.removeAll(branch: w.branch, in: w.main, git: DiffLoader.runEnv)
        if deleteBranch { git(["branch", force ? "-D" : "-d", w.branch], in: w.main) }
    }

    private static func keepFolder(_ w: Info, _ why: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { StorageIssues.shared.report("Worktree \(w.branch) не удалён: \(why)") } }
    }

    /// Worktrees left on disk (e.g. after the app was quit).
    static func scan(root: URL = Worktrees.root) -> [Info] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Info] = []
        for dir in projects {
            for wt in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                // Being removed.
                if wt.lastPathComponent.hasPrefix(WorktreeSnapshots.asidePrefix) { continue }
                if ContainerStore.shared.isContainer(wt) {
                    // What is inside isn't trusted.
                    if let r = ContainerStore.shared.record(wt) { out.append(r.info) }
                    continue
                }
                // .git file: "gitdir: /main/.git/worktrees/<name>"
                guard let s = try? String(contentsOf: wt.appendingPathComponent(".git"), encoding: .utf8) else { continue }
                let gitdir = s.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let cut = gitdir.range(of: "/.git/worktrees/") else { continue }
                let main = URL(fileURLWithPath: String(gitdir[..<cut.lowerBound]))
                let branch = git(["branch", "--show-current"], in: wt).out.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(Info(path: wt, main: main, branch: branch))
            }
        }
        return out
    }
}
