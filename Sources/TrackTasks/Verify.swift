import Foundation
import TrackTasksCore

extension JobQueue {
    static let maxVerifyAttempts = 2

    /// Run the project's check; on failure hand the output back to the same Claude session.
    func verify(_ job: Job, command: String, model: ClaudeModel) {
        job.lastLine = "Проверка" + (command.isEmpty ? "" : ": \(command)")
        if !command.isEmpty { job.log.append("⚙︎ Проверка: $ \(command)") }
        let dir = job.runDir
        let project = job.cwd
        let task = group(job)
        let target = member(task, job.targetRepo)
        // A repaired merge check is about one repository; otherwise every one is checked with its own command.
        let single = job.fixesMergeCheck && target.owner != nil
        let gate = taskGate(job)
        let own = single ? [] : [(name: "", command: Optional(command), dir: dir, project: project)]
        let extra = (single ? [target] : task.parts).compactMap { p in
            p.worktree.map { (name: p.repoName, command: single ? Optional(command) : nil, dir: $0.path, project: p.cwd) }
        }
        job.verifying = true
        Task.detached(priority: .userInitiated) {
            var r = Verify.Result(ok: true, output: "")
            var passed: [String] = []
            var skipped = false, isTask = false
            var refused: String?
            var command = command, place = ""
            // One at a time, so that two check locks are never held together.
            for c in own + extra {
                command = c.command ?? MergeRunner.command(c.project)
                let taskGate = c.name.isEmpty ? gate : nil
                if MergeRunner.needsMac(command, in: c.dir) { skipped = true; command = "" }
                if command.isEmpty, taskGate == nil { continue }
                if await MainActor.run(body: { job.cancelRequested }) { break }
                let p = Verify.run(command, taskGate, in: c.dir, project: c.project) { p in
                    Task { @MainActor in
                        guard job.verifying else { return }
                        job.verifyProcess = p
                        if job.cancelRequested { p.kill() }
                    }
                }
                r = p.result
                refused = refused ?? p.refused
                if !p.command.isEmpty { command = p.command }
                isTask = p.isTask
                guard r.ok else {
                    if !c.name.isEmpty { place = " в репозитории «\(c.name)» (\(c.dir.path))" }
                    break
                }
                passed += p.passed.map { c.name.isEmpty ? $0 : "\(c.name): \($0)" }
            }
            let (result, command_, place_, passed_, skipped_, refused_, isTask_) = (r, command, place, passed, skipped, refused, isTask)
            await MainActor.run {
                let (r, command, place, passed) = (result, command_, place_, passed_)
                let unchecked = skipped_ ? "Не проверено: " + MergeRunner.macOnly : ""
                job.verifying = false
                job.verifyProcess = nil
                if job.cancelRequested {
                    job.cancelRequested = false
                    job.lastLine = "Остановлено во время проверки"
                    self.finish(job, .cancelled)
                } else if r.ok, let why = refused_ {
                    // The agent can't settle it, so no attempts are spent.
                    job.verifyFailed = true
                    job.verifyNote = [Self.taskCheckRefused + why, unchecked, passed.isEmpty ? "" : "Прошли: " + passed.joined(separator: "; ")]
                        .filter { !$0.isEmpty }.joined(separator: ". ")
                    job.log.append("⚙︎ ✗ " + job.verifyNote)
                    self.finish(job, .done)
                } else if r.ok {
                    job.verifyNote = [unchecked, passed.isEmpty ? "" : Evidence.passedMark + passed.joined(separator: "; ")]
                        .filter { !$0.isEmpty }.joined(separator: ". ")
                    if skipped_ { job.log.append("⚙︎ " + unchecked) }
                    job.verifyFailed = false
                    if !passed.isEmpty { job.log.append("⚙︎ ✓ Проверка прошла") }
                    self.finish(job, .done)
                } else if r.timedOut {
                    // Not a code error: Claude can't fix a slow check, so don't spend attempts on it.
                    job.verifyFailed = true
                    job.verifyNote = "Проверка не уложилась в \(Int(Verify.timeout / 60)) мин: \(command)\(place)"
                    job.log.append("⚙︎ ✗ " + job.verifyNote + "\n" + r.output)
                    self.finish(job, .done)
                } else if self.pipelineTask(job)?.pipeline?.overBudget == true {
                    job.verifyFailed = true
                    job.verifyNote = "Проверка не прошла, бюджет пайплайна исчерпан: \(command)"
                    job.log.append("⚙︎ ✗ " + job.verifyNote + "\n" + r.output)
                    self.finish(job, .done)
                } else if job.verifyAttempts < Self.maxVerifyAttempts, job.sessionID != nil || !self.capabilities(job).contains(.resume) {
                    job.verifyAttempts += 1
                    job.log.append("⚙︎ ✗ Проверка упала — попытка исправить \(job.verifyAttempts)/\(Self.maxVerifyAttempts)")
                    job.lastLine = "Проверка упала, агент исправляет (\(job.verifyAttempts)/\(Self.maxVerifyAttempts))"
                    let resumes = self.capabilities(job).contains(.resume)
                    var prompt = """
                    Проверка \(isTask_ ? "задачи" : "проекта") `\(command)`\(place) упала. Вывод (конец):
                    ```
                    \(r.output)
                    ```
                    Исправь причину минимальными правками. Не отключай проверки и тесты, поле verify не меняй.
                    """
                    // A new session doesn't know the task.
                    if !resumes { prompt = job.prompt + "\n\nРабота уже сделана, осталось исправить проверку.\n" + prompt }
                    self.launch(job, model: model, prompt: prompt, resume: resumes ? job.sessionID : nil,
                                turn: "Исправление проверки \(job.verifyAttempts)/\(Self.maxVerifyAttempts)")
                } else {
                    job.verifyFailed = true
                    job.verifyNote = "Проверка не прошла после \(job.verifyAttempts) попыток: \(command)\(place)"
                    job.log.append("⚙︎ ✗ " + job.verifyNote + "\n" + r.output)
                    self.finish(job, .done)
                }
            }
        }
    }
}

/// Runs the project's check command (`verify:` in about.md) with a login shell and a timeout.
enum Verify {
    struct Result { let ok: Bool; let output: String; var timedOut = false }
    /// Big projects (Rust workspaces) build for a long time, often several lanes at once.
    static let timeout: TimeInterval = 30 * 60

    /// One check per project at a time: parallel builds fight for the same lock and target dir,
    /// and waiting for a neighbour must not eat the timeout.
    private static let gates = Gates()
    private final class Gates: @unchecked Sendable {
        private let lock = NSLock()
        private var byProject: [String: NSLock] = [:]
        func gate(_ key: String) -> NSLock {
            lock.lock(); defer { lock.unlock() }
            if let g = byProject[key] { return g }
            let g = NSLock()
            byProject[key] = g
            return g
        }
    }

    /// The project's check lock, taken; nil — cancelled while waiting. Unlock on the same thread.
    static func acquire(_ project: URL, cancelled: () -> Bool) -> NSLock? {
        let gate = gates.gate(TaskRepos.canonical(project))
        while !cancelled() {
            if gate.lock(before: Date().addingTimeInterval(0.3)) { return gate }
        }
        return nil
    }

    /// The project's check and the task's own under one lock.
    static func run(_ command: String, _ task: TaskVerifyGate?, in dir: URL, project: URL, onStart: ((RunningCommand) -> Void)? = nil) -> Pair {
        let gate = gates.gate(TaskRepos.canonical(project))
        gate.lock(); defer { gate.unlock() }
        return pair(command, task, in: dir, onStart: onStart)
    }

    /// The check itself; the caller holds the project's lock (it isn't recursive).
    static func execute(_ command: String, in dir: URL, timeout: TimeInterval = Verify.timeout, onStart: ((RunningCommand) -> Void)? = nil) -> Result {
        if ContainerStore.shared.isContainer(dir) {
            let t0 = Date()
            let r = ContainerStore.shared.run(command, in: dir, timeout: timeout, onStart: onStart)
            let timedOut = !r.ok && Date().timeIntervalSince(t0) >= timeout
            return Result(ok: r.ok, output: VerifyErrors.tail(r.out + r.err, limit: 5000) + (timedOut ? "\n[таймаут \(Int(timeout / 60)) мин]" : ""),
                          timedOut: timedOut)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["CI"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); data.append(d); if data.count > 400_000 { data = data.suffix(200_000) }; lock.unlock()
        }
        do { try p.run() } catch { return Result(ok: false, output: error.localizedDescription) }
        onStart?(.process(p))
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        var timedOut = false
        var stacks = ""
        if p.isRunning {
            timedOut = true
            // Killed, it loses its buffered output: the stacks are all that tells where it hung.
            stacks = HangReport.take(p.processIdentifier)
            ProcessTree.killTree(p.processIdentifier)
            p.waitUntilExit()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); data.append(pipe.fileHandleForReading.readDataToEndOfFile()); let all = data; lock.unlock()
        var text = String(decoding: all, as: UTF8.self)
        text = VerifyErrors.tail(text, limit: 5000)
        if timedOut { text += "\n[таймаут \(Int(timeout / 60)) мин]" + (stacks.isEmpty ? "" : "\n" + stacks) }
        return Result(ok: !timedOut && p.terminationStatus == 0, output: text, timedOut: timedOut)
    }
}
