import Darwin
import Foundation

/// Shared list of dev-server ports handed out by all running copies of the app (and builds), kept in one file under flock.
/// A record belongs to a process (pid + its start time, so a reused pid is not mistaken for the owner); records of dead processes are dropped.
public struct PortLedger: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var port: Int
        public var pid: Int32
        /// Start time of the owner process, seconds since 1970; nil if unknown.
        public var started: Double?
        public var folder: String
        public var name: String
        public init(port: Int, pid: Int32, started: Double?, folder: String, name: String) {
            self.port = port; self.pid = pid; self.started = started; self.folder = folder; self.name = name
        }
    }

    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case noFreePort(from: Int, to: Int)
        case ledger(String)
        public var errorDescription: String? {
            switch self {
            case .noFreePort(let a, let b): "Нет свободного порта в диапазоне \(a)–\(b): все заняты другими серверами или программами. Остановите лишние серверы."
            case .ledger(let m): "Не удалось записать учёт портов: \(m)"
            }
        }
    }

    public let url: URL
    /// Is the process with this pid and start time alive? Replaceable in tests.
    public var isAlive: @Sendable (Int32, Double?) -> Bool
    /// Can the port be bound right now? Replaceable in tests.
    public var isFree: @Sendable (Int) -> Bool
    public var range = 500

    public init(url: URL = PortLedger.defaultURL,
                isAlive: @escaping @Sendable (Int32, Double?) -> Bool = PortLedger.processAlive,
                isFree: @escaping @Sendable (Int) -> Bool = { RunCommands.isFree($0) }) {
        self.url = url; self.isAlive = isAlive; self.isFree = isFree
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TrackTasks/dev-ports.json")
    }

    // MARK: Operations

    /// Reserves a port: free to bind and not in the ledger. Throws `noFreePort` instead of returning a busy one.
    public func claim(from start: Int = 3000, pid: Int32 = getpid(), folder: String, name: String) throws -> Int {
        try locked { entries in
            let taken = Set(entries.map(\.port))
            let end = min(start + range, 65535)
            guard let p = (start..<end).first(where: { !taken.contains($0) && isFree($0) }) else {
                throw Failure.noFreePort(from: start, to: end - 1)
            }
            entries.append(Entry(port: p, pid: pid, started: Self.startTime(of: pid), folder: folder, name: name))
            return p
        }
    }

    /// Frees one port of this process.
    public func release(port: Int, pid: Int32 = getpid()) {
        _ = try? locked { entries in entries.removeAll { $0.port == port && $0.pid == pid } }
    }

    /// Frees ports of this process in the folder (all of them if `folder` is nil).
    public func release(pid: Int32 = getpid(), folder: String? = nil) {
        _ = try? locked { entries in entries.removeAll { $0.pid == pid && (folder == nil || $0.folder == folder) } }
    }

    /// Entries of living processes (dead ones are removed from the file).
    public func entries() -> [Entry] { (try? locked { $0 }) ?? [] }

    // MARK: File

    private func locked<T>(_ body: (inout [Entry]) throws -> T) throws -> T {
        let dir = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw Failure.ledger(error.localizedDescription) }
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw Failure.ledger(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.ledger(String(cString: strerror(errno))) }
        defer { flock(fd, LOCK_UN) }

        var list: [Entry] = []
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Entry].self, from: data) { list = decoded }
        let live = list.filter { isAlive($0.pid, $0.started) }
        var work = live
        let result = try body(&work)
        if work != list {
            do { try JSONEncoder().encode(work).write(to: url, options: .atomic) } catch { throw Failure.ledger(error.localizedDescription) }
        }
        return result
    }

    // MARK: Processes

    public static let processAlive: @Sendable (Int32, Double?) -> Bool = { pid, started in
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return false }
        // Same pid, other process (pid reused): start times differ.
        if let started, let now = startTime(of: pid), abs(now - started) > 1 { return false }
        return true
    }

    /// Start time of a process via sysctl, nil if it can't be read.
    public static func startTime(of pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }
}
