import Darwin
import Foundation

/// Files an ACP agent may ask the app to read and write: only inside its folders. Not a sandbox: the agent's own
/// tools don't go through here.
public struct ACPAccess: Sendable {
    public let access: AgentAccess
    public let cwd: URL
    public let addDirs: [URL]

    public init(access: AgentAccess, cwd: URL, addDirs: [URL] = []) {
        self.access = access
        self.cwd = cwd
        self.addDirs = addDirs
    }

    public enum Refusal: Error, Equatable {
        case outside, protected, notFound, notAFile, tooBig, notText
        case failed(String)

        public var message: String {
            switch self {
            case .outside: "Путь вне папки запуска"
            case .protected: "Запись сюда не разрешена"
            case .notFound: "Файл не найден"
            case .notAFile: "Не обычный файл"
            case .tooBig: "Файл слишком большой"
            case .notText: "Файл не в UTF-8"
            case .failed(let s): s
            }
        }

        public var code: Int { self == .notFound ? -32002 : -32602 }
    }

    public static let maxSize = 10 << 20

    /// Real path of a folder that is inside (or is one of) the run's folders.
    public func folder(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), let real = CodexPolicy.real(path) else { return nil }
        var st = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return root(of: real) == nil ? nil : real
    }

    /// `line` counts from 1; the schema also lets 0 through.
    public func read(_ path: String, line: Int? = nil, limit: Int? = nil) throws -> String {
        let real = try inside(path)
        // No link anywhere in the resolved path: it can't be replaced by one after the check. Nonblocking: FIFO.
        let fd = open(real, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.refusal() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Refusal.notAFile }
        guard let actual = Self.path(of: fd), root(of: actual) != nil else { throw Refusal.outside }
        guard st.st_size <= Self.maxSize else { throw Refusal.tooBig }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { throw Self.refusal() }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
            guard data.count <= Self.maxSize else { throw Refusal.tooBig }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Refusal.notText }
        if line == nil, limit == nil { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.dropFirst(max(0, (line ?? 1) - 1)).prefix(max(0, limit ?? lines.count)).joined(separator: "\n")
    }

    /// The whole file is replaced at once; missing folders are created.
    public func write(_ path: String, _ content: String) throws {
        let real = try inside(path)
        guard mayWrite(real) else { throw Refusal.protected }
        guard content.utf8.count <= Self.maxSize else { throw Refusal.tooBig }
        var dir = (real as NSString).deletingLastPathComponent
        let file = (real as NSString).lastPathComponent
        var missing: [String] = []
        var fd: Int32 = -1
        while true {
            fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            if fd >= 0 { break }
            guard errno == ENOENT, dir != "/" else { throw Self.refusal() }
            missing.insert((dir as NSString).lastPathComponent, at: 0)
            dir = (dir as NSString).deletingLastPathComponent
        }
        defer { close(fd) }
        for name in missing {
            if mkdirat(fd, name, 0o755) != 0, errno != EEXIST { throw Self.refusal() }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.refusal() }
            close(fd)
            fd = next
        }
        guard let actual = Self.path(of: fd), root(of: actual + "/" + file) != nil, mayWrite(actual + "/" + file) else { throw Refusal.outside }
        var mode: mode_t = 0o644
        var st = stat()
        if fstatat(fd, file, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard st.st_mode & S_IFMT == S_IFREG else { throw Refusal.notAFile }
            mode = st.st_mode & 0o777
        } else if errno != ENOENT { throw Self.refusal() }
        let temp = ".tracktasks-" + UUID().uuidString
        let out = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw Self.refusal() }
        do {
            defer { close(out) }
            var bytes = Data(content.utf8)
            while !bytes.isEmpty {
                let n = bytes.withUnsafeBytes { Darwin.write(out, $0.baseAddress, $0.count) }
                guard n > 0 else {
                    let e = Self.refusal()
                    unlinkat(fd, temp, 0)
                    throw e
                }
                bytes = Data(bytes.dropFirst(n))
            }
            fchmod(out, mode)
        }
        guard renameat(fd, temp, fd, file) == 0 else {
            let e = Self.refusal()
            unlinkat(fd, temp, 0)
            throw e
        }
    }

    private var roots: [String] { ([cwd] + addDirs).compactMap { CodexPolicy.real($0.path) } }

    private func root(of real: String) -> String? {
        roots.filter { $0 != "/" && (real == $0 || real.hasPrefix($0 + "/")) }.max { $0.count < $1.count }
    }

    private func inside(_ path: String) throws -> String {
        guard access != .answer, path.hasPrefix("/"), !path.contains("\0"), let real = CodexPolicy.real(path),
              let root = root(of: real), root != real else { throw Refusal.outside }
        return real
    }

    private func mayWrite(_ real: String) -> Bool {
        guard let root = root(of: real), root != real else { return false }
        let parts = real.dropFirst(root.count + 1).lowercased().split(separator: "/")
        // Git internals and agents' own settings are not code.
        if parts.contains(where: { [".git", ".codex", ".agents", ".claude"].contains($0) }) { return false }
        switch access {
        case .answer: return false
        case .coding: return true
        case .planning:
            if root != CodexPolicy.real(cwd.path) { return true }
            return parts.count > 1 ? parts[0] == "tasks" : parts == ["about.md"] || parts == ["spectrack.md"]
        }
    }

    private static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func refusal() -> Refusal {
        switch errno {
        case ENOENT, ENOTDIR: .notFound
        case ELOOP: .outside
        case EISDIR: .notAFile
        default: .failed(String(cString: strerror(errno)))
        }
    }
}
