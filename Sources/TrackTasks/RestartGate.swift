import AppKit
import TrackTasksCore

/// Keeps the restart for an update away from work in progress: waits for it to end, then asks.
@Observable @MainActor
final class RestartGate {
    /// The restart was put off and waits for the work to end or for the user.
    private(set) var isPending = false
    private(set) var asking = false
    /// «Позже»: no more questions by itself, the button in Settings stays.
    private(set) var declined = false

    @ObservationIgnored private var proceed: (() -> Void)?
    @ObservationIgnored private let sources: @MainActor () -> [UpdatePolicy.Busy]
    @ObservationIgnored private let freeze: @MainActor (Bool) -> Void
    @ObservationIgnored private let ask: @MainActor (_ answer: @escaping @MainActor (Bool) -> Void) -> Void
    /// The app is still here long after the quit began: something cancelled it.
    @ObservationIgnored private let thawAfter: TimeInterval
    @ObservationIgnored private var thaw: DispatchWorkItem?

    init(sources: @escaping @MainActor () -> [UpdatePolicy.Busy], freeze: @escaping @MainActor (Bool) -> Void,
         thawAfter: TimeInterval = 60,
         ask: @escaping @MainActor (_ answer: @escaping @MainActor (Bool) -> Void) -> Void = RestartGate.alert) {
        self.sources = sources
        self.freeze = freeze
        self.thawAfter = thawAfter
        self.ask = ask
    }

    var busy: [UpdatePolicy.Busy] { sources() }

    /// The user has agreed to restart. True = not now, `handler` is called later, after one more agreement.
    func postpone(_ handler: @escaping () -> Void) -> Bool {
        guard !busy.isEmpty else { hold(); return false }
        wait(for: handler)
        return true
    }

    /// The last barrier: a quit asked for by the updater. An ordinary quit isn't stopped.
    func mayTerminate(byUpdater: Bool) -> Bool {
        guard byUpdater, !busy.isEmpty else { return true }
        release()
        // The installer goes on when the app quits, whoever asked it to.
        wait { NSApp.terminate(nil) }
        return false
    }

    /// «Перезапустить сейчас».
    func restart() {
        guard let p = proceed else { return }
        guard busy.isEmpty else {
            declined = false
            return recheck()
        }
        proceed = nil
        isPending = false
        hold()
        p()
    }

    /// The update ended without a restart.
    func cancel() {
        proceed = nil
        isPending = false
        declined = false
        release()
    }

    private func wait(for handler: @escaping () -> Void) {
        proceed = handler
        isPending = true
        declined = false
        recheck()
    }

    /// On changes of what is being done, no polling.
    private func recheck() {
        guard proceed != nil, !declined else { return }
        let free = withObservationTracking { sources().isEmpty } onChange: { [weak self] in
            // Called before the change.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recheck() } }
        }
        guard free, !asking else { return }
        asking = true
        ask { [weak self] yes in
            guard let self else { return }
            asking = false
            if yes { restart() } else { declined = true }
        }
    }

    private func hold() {
        freeze(true)
        thaw?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.release() } }
        thaw = w
        DispatchQueue.main.asyncAfter(deadline: .now() + thawAfter, execute: w)
    }

    private func release() {
        thaw?.cancel()
        thaw = nil
        freeze(false)
    }

    static func alert(_ answer: @escaping @MainActor (Bool) -> Void) {
        // Not from a main-queue block: a modal loop inside it would stop the queue for as long as the question is open.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                let a = NSAlert()
                a.messageText = "Обновление готово"
                a.informativeText = "Работа, которая мешала перезапуску, закончилась."
                a.addButton(withTitle: "Перезапустить сейчас")
                a.addButton(withTitle: "Позже")
                NSApp.activate()
                answer(a.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}

extension JobQueue {
    /// Work of the queue a restart would cut off. Waiting jobs don't count: they are saved.
    var restartBusy: [UpdatePolicy.Busy] {
        var out: [UpdatePolicy.Busy] = []
        for j in allMembers {
            if j.state == .running || j.verifying || j.checkpointing || j.settingUp || j.answering || creatingWorktree.contains(j.id) {
                out.append(.task(j.title))
            } else if j.mergePhase != nil || j.worktreeBusy {
                out.append(.merge(j.title))
            }
        }
        if mergeBatch != nil || !autoMerging.isEmpty || restarting || cleaning || !busyOrphans.isEmpty, !out.contains(where: { if case .merge = $0 { true } else { false } }) {
            out.append(.merge(""))
        }
        if !gitBusy.isEmpty { out.append(.git) }
        // Members of one task share their busy state.
        var seen = Set<UpdatePolicy.Busy>()
        return out.filter { seen.insert($0).inserted }
    }
}

extension Terminals {
    /// Until the sessions of earlier runs are known they count too.
    var liveCount: Int { tabs.values.joined().filter(\.isRunning).count + (restoring ? 1 : 0) }
}

extension DevServers {
    var liveCount: Int { servers.values.joined().filter(\.isRunning).count }
}

extension RestartGate {
    /// Everything the app may be doing.
    static func busy(jobs: JobQueue, terminals: Terminals? = nil, servers: Int? = nil, chat: Bool) -> [UpdatePolicy.Busy] {
        var out = jobs.restartBusy
        if MergeToken.anyLive, !out.contains(where: { if case .merge = $0 { true } else { false } }) { out.append(.merge("")) }
        let tabs = (terminals ?? .shared).liveCount, servers = servers ?? DevServers.shared.liveCount
        if tabs > 0 { out.append(.terminal(tabs)) }
        if servers > 0 { out.append(.server(servers)) }
        if chat { out.append(.chat) }
        return out
    }
}
