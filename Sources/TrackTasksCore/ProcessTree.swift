import Darwin
import Foundation

/// Processes started from a terminal tab: what has to die with it.
public enum ProcessTree {
    /// Start time makes the identity safe against pid reuse.
    public struct ID: Hashable, Sendable {
        public let pid: pid_t
        public let started: Int64
        public init(pid: pid_t, started: Int64) { self.pid = pid; self.started = started }
    }

    public struct Entry: Sendable {
        public let id: ID
        public let parent: pid_t
        public let session: pid_t
        public init(id: ID, parent: pid_t, session: pid_t) { self.id = id; self.parent = parent; self.session = session }
    }

    /// `root`, everything in its session (background jobs, nohup) and all descendants, including ones with their own session.
    public static func members(of root: pid_t, in all: [Entry]) -> Set<ID> {
        guard root > 1 else { return [] }
        let children = Dictionary(grouping: all, by: \.parent)
        var found: Set<ID> = []
        var next = all.filter { $0.id.pid == root || $0.session == root }
        while let e = next.popLast() {
            guard e.id.pid > 1, found.insert(e.id).inserted else { continue }
            next += children[e.id.pid] ?? []
        }
        return found
    }

    /// Live (not zombie) processes of this Mac.
    public static func snapshot() -> [Entry] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = buf.count * stride
            // ENOMEM: the list grew meanwhile.
            guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { continue }
            return buf.prefix(size / stride).compactMap { k in
                guard k.kp_proc.p_pid > 1, Int32(k.kp_proc.p_stat) != SZOMB else { return nil }
                let t = k.kp_proc.p_un.__p_starttime
                return Entry(id: ID(pid: k.kp_proc.p_pid, started: Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec)),
                             parent: k.kp_eproc.e_ppid, session: getsid(k.kp_proc.p_pid))
            }
        }
        return []
    }

    public static func alive(_ ids: Set<ID>) -> Set<ID> {
        ids.isEmpty ? [] : ids.intersection(snapshot().map(\.id))
    }

    /// SIGTERM to `root` and all it started; whatever is still alive after 2 s gets SIGKILL.
    public static func killTree(_ root: pid_t) {
        let ids = members(of: root, in: snapshot())
        signal(ids, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { signal(alive(ids), SIGKILL) }
    }

    static func signal(_ ids: Set<ID>, _ signals: Int32...) {
        for id in ids { for s in signals { kill(id.pid, s) } }
    }
}

extension ProcessTree {
    /// Which of `folders` some process works in (its current folder is there). Processes of other users aren't visible.
    /// nil = unknown.
    public static func working(in folders: [String]) -> Set<String>? {
        let all = snapshot()
        guard !all.isEmpty else { return nil }
        let real = folders.map { ($0, TaskRepos.canonical(URL(fileURLWithPath: $0))) }
        var out = Set<String>()
        for e in all where e.id.pid != getpid() {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(e.id.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let cwd = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            for (f, r) in real where cwd == r || cwd.hasPrefix(r + "/") { out.insert(f) }
        }
        return out
    }
}

extension ProcessTree {
    /// The port is listened on by `root` or what it started, and by nobody else of this user.
    /// The port in a server's output can't be trusted: it may name another local service. Not on the main thread.
    public static func listens(on port: Int, root: pid_t) -> Bool {
        let all = snapshot()
        let own = Set(members(of: root, in: all).map(\.pid))
        guard !own.isEmpty else { return false }
        var found = false
        for e in all where hasListener(e.id.pid, port) {
            guard own.contains(e.id.pid) else { return false }
            found = true
        }
        return found
    }

    /// Processes of other users look as if they had none.
    static func hasListener(_ pid: pid_t, _ port: Int) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP), info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let p = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).byteSwapped
            if Int(p) == port { return true }
        }
        return false
    }
}
