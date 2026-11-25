import AppKit
import TrackTasksCore

extension Worktrees.Info {
    var mergeSite: SafeMerge.Site { .init(folder: path, main: main, branch: branch, links: Set(Worktrees.links(of: path))) }
}

/// Cancels one merge: kills its running check. Every live merge is cancelled when the app quits.
final class MergeToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: RunningCommand?

    private static let registry = Registry()
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var live: [ObjectIdentifier: MergeToken] = [:]
        init() {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let all = Array(self.live.values)
                self.lock.unlock()
                all.forEach { $0.cancel() }
            }
        }
        func set(_ t: MergeToken, live on: Bool) {
            lock.lock(); defer { lock.unlock() }
            live[ObjectIdentifier(t)] = on ? t : nil
        }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return live.isEmpty }
    }

    /// Changes whenever a merge begins or ends.
    @Observable @MainActor final class Changes {
        static let shared = Changes()
        fileprivate(set) var count = 0
    }
    /// A merge is going, also one outside the queue.
    @MainActor static var anyLive: Bool {
        _ = Changes.shared.count
        return !registry.isEmpty
    }
    private static func changed() {
        DispatchQueue.main.async { MainActor.assumeIsolated { Changes.shared.count += 1 } }
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        p?.kill()
    }

    func started(_ p: RunningCommand) {
        lock.lock()
        process = p
        let dead = cancelled
        lock.unlock()
        if dead { p.kill() }
    }

    func begin() { Self.registry.set(self, live: true); Self.changed() }
    func end() { Self.registry.set(self, live: false); Self.changed() }
}

/// `SafeMerge` with the real git, the project's `verify` and its check lock.
enum MergeRunner {
    /// Runs on its own thread: it may wait for the lock and the check for a long time.
    /// On success the worktree and its branch are removed, unless `keep`. `scripts`: with its teardown.
    static func run(_ w: Worktrees.Info, known: SafeMerge.Check? = nil, artifacts: [String] = [],
                    allowed: SafeMerge.Allowed, token: MergeToken, task: TaskVerifyGate? = nil, keep: Bool = false, scripts: Bool = true,
                    onPhase: @escaping @MainActor @Sendable (SafeMerge.Phase) -> Void = { _ in },
                    mayLand: @escaping @MainActor @Sendable () -> String? = { nil }) async -> SafeMerge.Report {
        token.begin()
        defer { token.end() }
        return await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let report = locked(w, known, artifacts, allowed, token, task, onPhase, mayLand)
                if case .merged = report.outcome, !keep { cleanUp(w, scripts: scripts) }
                c.resume(returning: report)
            }
        }
    }

    private static func locked(_ w: Worktrees.Info, _ known: SafeMerge.Check?, _ artifacts: [String],
                               _ allowed: SafeMerge.Allowed, _ token: MergeToken, _ task: TaskVerifyGate?,
                               _ onPhase: @escaping @MainActor @Sendable (SafeMerge.Phase) -> Void,
                               _ mayLand: @escaping @MainActor @Sendable () -> String?) -> SafeMerge.Report {
        let git: SafeMerge.Runner = DiffLoader.runEnv
        // Ask before waiting for the lock and the check.
        if let stop = SafeMerge.precheck(w.mergeSite, allowed: allowed, git: git) {
            return .init(outcome: stop, check: known, artifacts: artifacts)
        }
        // Held to the end: main is read, checked and moved with no other check or merge of the project in between.
        guard let gate = Verify.acquire(w.main, cancelled: { token.isCancelled }) else {
            return .init(outcome: .cancelled, check: known, artifacts: artifacts)
        }
        defer { gate.unlock() }
        let taskCheck = task?.decide() ?? .none
        if let r = taskCheck.refusal { return .init(outcome: .failed(taskCheckRefused(r)), check: known, artifacts: artifacts) }
        let hooks = SafeMerge.Hooks(
            verify: { cmd in
                let r = Verify.execute(cmd, in: w.path, onStart: token.started)
                return .init(ok: r.ok, output: r.output, timedOut: r.timedOut)
            },
            isCancelled: { token.isCancelled },
            onPhase: { p in DispatchQueue.main.async { MainActor.assumeIsolated { onPhase(p) } } },
            mayLand: {
                // The command must still be the one that has passed.
                let now = task?.decide() ?? .none
                if let r = now.refusal { return taskCheckRefused(r) }
                if !TaskVerify.same(now.command, taskCheck.command) { return "проверка задачи изменилась во время слияния — слей ещё раз" }
                return DispatchQueue.main.sync { MainActor.assumeIsolated { mayLand() } }
            })
        return SafeMerge.run(w.mergeSite, command: command(w), taskCommand: taskCheck.command, known: known, artifacts: artifacts,
                             allowed: allowed, git: git, hooks: hooks)
    }

    /// The same for a branch: a container's code is never checked on the host, so a check that needs the Mac isn't run
    /// at all and the branch is «не проверено».
    static func command(_ w: Worktrees.Info) -> String {
        let c = command(w.main)
        return needsMac(c, in: w.path) ? "" : c
    }

    static func needsMac(_ command: String, in folder: URL) -> Bool {
        ContainerVerify.needsMac(command) && ContainerStore.shared.isContainer(folder)
    }

    static let macOnly = "проверке нужен Mac, а код из контейнера на нём не запускается — посмотри diff и слей вручную"

    static func taskCheckRefused(_ r: TaskVerify.Refusal) -> String { "проверка задачи не запущена: " + r.why }

    /// Current `verify:` of the main folder's about.md — the job may have an old one.
    static func command(_ main: URL) -> String {
        guard let t = try? String(contentsOf: main.appendingPathComponent("about.md"), encoding: .utf8) else { return "" }
        return (Frontmatter.parse(t).0["verify"] ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func cleanUp(_ w: Worktrees.Info, scripts: Bool = true) {
        Worktrees.remove(w, deleteBranch: true, force: false, scripts: scripts)
    }

    /// Files that went away with the worktree without being committed.
    static func removed(_ artifacts: [String]) -> String {
        artifacts.isEmpty ? "" : "С worktree удалены файлы, появившиеся во время проверки: \(DirtyFiles.summary(artifacts))"
    }

    static func stashNote(_ label: String?) -> String {
        label.map { ". Твои правки основной папки — в git stash («\($0)»): git stash pop" } ?? ""
    }

    static func elsewhere(_ branches: [String]) -> String {
        "Слито до закрытия приложения, но не в текущую ветку основной папки, а в «\(DirtyFiles.summary(branches))». "
            + "Worktree оставлен: вернись на ту ветку и нажми «Слить», чтобы его убрать"
    }

    static func text(_ report: SafeMerge.Report) -> String {
        let check = report.check
        switch report.outcome {
        case .merged(_, let note, _):
            let head = check?.state == .unverified ? "Слито в основную ветку — не проверено (verify в about.md пуст или не выполняется в контейнере)" : "Слито в основную ветку"
            return [head, note, removed(report.artifacts)].filter { !$0.isEmpty }
                .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: ". ")
        case .conflict(let f):
            return "Конфликт с основной веткой — слияние отменено, основная папка не тронута: \(DirtyFiles.summary(f, limit: 8))"
        case .red:
            return "Не слито: вместе со свежей основной веткой проверка не проходит (\(check?.failedCommand ?? "verify")). Основная папка не тронута"
        case .timedOut:
            return "Не слито: проверка не уложилась в \(Int(Verify.timeout / 60)) мин. Основная папка не тронута"
        case .moved:
            return "Не слито: основная ветка сдвигалась во время проверки (\(SafeMerge.maxRepeats + 1) раза подряд). Слей, когда в ней станет тихо"
        case .cancelled:
            return "Слияние остановлено, основная папка не тронута"
        case .overlap(let f):
            return "Не слито: ветка меняет файлы с незакоммиченными правками в main — \(DirtyFiles.summary(f))"
        case .mainConflict(let f):
            return "В основной папке неразрешённые конфликты: \(DirtyFiles.summary(f, limit: 8)). "
                + "Сначала разреши их (кнопка «Конфликты в main» или вручную + git add), потом сливай."
        case .failed(let m):
            return "Не слито: " + m
        }
    }
}
