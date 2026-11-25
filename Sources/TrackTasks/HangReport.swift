import Foundation
import TrackTasksCore

/// What a check that ran out of time was doing: its processes and their stacks. Taken before they are killed.
enum HangReport {
    private static let maxProcesses = 5
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    /// Blocks for at most about half a minute.
    static func take(_ root: pid_t) -> String {
        let pids = ProcessTree.members(of: root, in: ProcessTree.snapshot()).map(\.pid).sorted()
        guard !pids.isEmpty else { return "" }
        let list = run("/bin/ps", ["-o", "pid=,ppid=,etime=,time=,stat=,command=", "-p", pids.map(String.init).joined(separator: ",")], timeout: 5)
        let rows = list.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true) }
        let targets = rows.compactMap { f -> (pid: pid_t, name: String)? in
            guard f.count > 5, let pid = pid_t(f[0]) else { return nil }
            var name = (String(f[5]) as NSString).lastPathComponent
            if name.hasPrefix("-") { name.removeFirst() }
            return shells.contains(name) ? nil : (pid, name)
        }.prefix(maxProcesses)

        let lock = NSLock()
        var stacks: [pid_t: String] = [:]
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let t = targets[i]
            let s = HangSample.trim(run("/usr/bin/sample", ["\(t.pid)", "1", "-mayDie"], timeout: 20))
            lock.withLock { stacks[t.pid] = s }
        }
        let processes = list.split(separator: "\n").prefix(30).map { String($0.prefix(300)) }.joined(separator: "\n")
        return "Процессы в момент таймаута:\n" + processes
            + targets.map { "\n\nСтек \($0.name) (\($0.pid)):\n" + (stacks[$0.pid] ?? "") }.joined()
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let r = TimedProcess.run(p, timeout: timeout)
        return r.out.isEmpty ? r.err : r.out
    }
}
