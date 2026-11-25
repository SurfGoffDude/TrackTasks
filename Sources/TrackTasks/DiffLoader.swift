import Foundation
import TrackTasksCore

extension DiffSource {
    /// Worktree job: branch commits plus uncommitted edits in the worktree; otherwise — the main folder.
    @MainActor
    init(job: Job) {
        if let w = job.worktree {
            self.init(title: "\(job.projectName) · \(job.title)", folder: w.path,
                      branch: .init(main: w.main, base: job.baseCommit, name: w.branch), jobID: job.home.id)
        } else {
            self.init(title: "\(job.projectName) · \(job.title)", folder: job.cwd, jobID: job.id)
        }
    }

    init(project: Project) {
        self.init(title: project.displayName, folder: project.url)
    }

    /// A commit against its first parent (the root — against the empty tree). Runs git: not on the main thread.
    init?(commit c: GitCommit, project: String, folder: URL) {
        guard let base = GitHistory.base(of: c, in: folder, git: DiffLoader.runEnv) else { return nil }
        let title = "\(c.id.prefix(8)) \(c.subject)"
        self.init(title: "\(project) · \(title)", folder: folder,
                  span: .init(from: base, to: c.id, title: c.isMerge ? "Слияние: сравнение с первым родителем" : String(c.id.prefix(8))))
    }

    var terminalCommand: String {
        if let span { return "git diff \(span.from)" + (span.to.map { " \($0)" } ?? "") }
        guard let branch else { return "git status && git diff HEAD" }
        let range = Shell.quote(branch.range)
        // `HEAD...` is about the main folder's HEAD, so the branch part always runs there.
        return "git -C \(Shell.quote(branch.main.path)) diff \(range) -- ; git status && git diff HEAD"
    }
}

enum DiffLoader {
    /// Runs git and parses its output off the main actor.
    static func load(_ source: DiffSource) async -> [DiffSection] {
        await Task.detached(priority: .userInitiated) {
            Log.git.measure("DiffLoader.load", source.title) {
                var source = source
                if let span = source.span, span.to == nil {
                    do {
                        let site = Checkpoints.Site(folder: source.folder, branch: source.spanBranch ?? "", links: Set(Worktrees.links(of: source.folder)))
                        source.span?.to = try Checkpoints.currentTree(site, git: runEnv)
                    } catch {
                        return [DiffSection.failed(error.localizedDescription)]
                    }
                }
                return DiffCollector.collect(source, skipUntracked: Set(Worktrees.links(of: source.folder)), git: run)
            }
        }.value
    }

    private static let maxOutput = 64 << 20

    /// Unlike `Worktrees.git`: never takes the index lock, keeps non-UTF-8 output, and stops at `maxOutput`.
    static func run(_ args: [String], in dir: URL) -> DiffCollector.Output { run(args, in: dir, max: maxOutput) }

    static func run(_ args: [String], in dir: URL, max: Int) -> DiffCollector.Output {
        if let why = ContainerStore.shared.refusal(dir) { return .init(ok: false, out: "", err: why) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + ContainerStore.shared.gitOptions(dir) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        Log.git.process("git", project: dir.lastPathComponent, command: args.joined(separator: " "))
        do { try p.run() } catch { return .init(ok: false, out: "", err: error.localizedDescription) }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        var data = Data()
        var cut = false
        while let chunk = try? out.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            if data.count >= max {
                cut = true
                p.terminate()
                break
            }
        }
        g.wait()
        p.waitUntilExit()
        return .init(ok: cut || p.terminationStatus == 0, out: String(decoding: data, as: UTF8.self),
                     err: String(decoding: errData, as: UTF8.self), cut: cut)
    }
}

extension DiffLoader {
    static func lastReject(_ source: DiffSource) async -> DiffReject.Undo? {
        guard source.branch != nil else { return nil }
        return await Task.detached(priority: .userInitiated) { DiffReject.last(source, git: runRaw) }.value
    }

    /// Byte-exact output and stdin, for patches.
    static func runRaw(_ args: [String], in dir: URL, input: Data?) -> DiffReject.Output {
        runEnv(args, in: dir, env: [:], input: input)
    }

    static func runEnv(_ args: [String], in dir: URL, env extra: [String: String], input: Data?) -> DiffReject.Output {
        if let why = ContainerStore.shared.refusal(dir) { return .init(status: -1, out: Data(), err: why) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + ContainerStore.shared.gitOptions(dir) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env.merge(extra) { $1 }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        Log.git.process("git", project: dir.lastPathComponent, command: args.joined(separator: " "))
        do { try p.run() } catch { return .init(status: -1, out: Data(), err: error.localizedDescription) }
        let g = DispatchGroup()
        if let input {
            let h = inp.fileHandleForWriting
            // git may exit before reading everything: an error, not a signal.
            _ = fcntl(h.fileDescriptor, F_SETNOSIGPIPE, 1)
            g.enter()
            DispatchQueue.global().async {
                try? h.write(contentsOf: input)
                try? h.close()
                g.leave()
            }
        }
        var errData = Data()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return .init(status: p.terminationStatus, out: data, err: String(decoding: errData, as: UTF8.self))
    }
}

/// «Просмотрено» marks: source → file id → fingerprint of the content that was viewed.
enum DiffViewed {
    private static let key = "diffViewed"
    private static let orderKey = "diffViewedOrder"
    private static let maxSources = 60

    static func load(_ source: DiffSource) -> [String: String] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]
        return all?[source.key] ?? [:]
    }

    static func save(_ marks: [String: String], for source: DiffSource) {
        let d = UserDefaults.standard
        var all = d.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var order = d.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == source.key }
        if marks.isEmpty {
            all[source.key] = nil
        } else {
            all[source.key] = marks
            order.append(source.key)
        }
        while order.count > maxSources { all[order.removeFirst()] = nil }
        d.set(all, forKey: key)
        d.set(order, forKey: orderKey)
    }
}
