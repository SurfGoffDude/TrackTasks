import Foundation

/// Local Unix socket between `tt` and the app. Folder 0700, socket 0600, and both sides check the other's user.
public enum QueueSocket {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackTasks/ipc/tt.sock")
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    static func errno(_ what: String, _ code: Int32 = Darwin.errno) -> QueueFailure {
        QueueFailure(.io, "\(what): \(String(cString: strerror(code)))")
    }

    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errno("socket") }
        prepare(fd)
        return fd
    }

    /// Not inherited by claude and terminals; a vanished peer is an error, not SIGPIPE.
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func timeout(_ fd: Int32, read: Int, write: Int) {
        for (opt, s) in [(SO_RCVTIMEO, read), (SO_SNDTIMEO, write)] {
            var t = timeval(tv_sec: s, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, opt, &t, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else {
            throw QueueFailure(.io, "слишком длинный путь сокета: \(path)")
        }
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    // MARK: Frames: 4 bytes of length (big endian) + JSON

    static func send(_ data: Data, to fd: Int32) throws {
        let n = UInt32(data.count)
        let frame = [UInt8](Data([UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]) + data)
        var off = 0
        while off < frame.count {
            let w = frame[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if w < 0, Darwin.errno == EINTR { continue }
            guard w > 0 else { throw errno("запись в сокет") }
            off += w
        }
    }

    static func receive(_ fd: Int32, limit: Int) throws -> Data {
        let head = try read(fd, 4)
        let n = head.reduce(0) { $0 << 8 | Int($1) }
        guard n <= limit else { throw QueueFailure(.usage, "слишком большое сообщение") }
        return try read(fd, n)
    }

    private static func read(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: min(max(count, 1), 64 << 10))
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let r = Darwin.read(fd, &buf, want)
            if r < 0, Darwin.errno == EINTR { continue }
            guard r >= 0 else { throw errno("чтение из сокета") }
            guard r > 0 else { throw QueueFailure(.io, "соединение закрыто") }
            out.append(contentsOf: buf[0..<r])
        }
        return out
    }
}

public final class QueueSocketServer: @unchecked Sendable {
    /// Called on a background thread, for several connections at once.
    public typealias Handler = @Sendable (QueueRequest) -> QueueResponse

    private static let maxConnections = 16
    private let url: URL
    private let peerUID: @Sendable (Int32) -> uid_t?
    private let handler: Handler
    private let accepting = DispatchQueue(label: "TrackTasks.ipc")
    private let working = DispatchQueue(label: "TrackTasks.ipc.work", attributes: .concurrent)
    private let lock = NSLock()
    private var connections = 0
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(url: URL, peerUID: @escaping @Sendable (Int32) -> uid_t? = QueueSocket.peerUID, handler: @escaping Handler) {
        self.url = url
        self.peerUID = peerUID
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        do { try open() } catch {
            stop()
            throw error
        }
    }

    private func open() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(dir.path, 0o700) != 0, Darwin.errno != EEXIST { throw QueueSocket.errno("папка сокета") }
        var st = stat()
        guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            throw QueueFailure(.io, "\(dir.path): не своя папка")
        }
        guard chmod(dir.path, 0o700) == 0 else { throw QueueSocket.errno("права папки сокета") }

        // Held while the app runs: a second copy must not take the socket away.
        lockFD = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw QueueSocket.errno("блокировка сокета") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw QueueFailure(.conflict, "команды tt queue уже принимает другая копия приложения")
        }
        if lstat(url.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else {
                throw QueueFailure(.io, "\(url.path): занято не сокетом приложения")
            }
            unlink(url.path)
        }

        let fd = try QueueSocket.make()
        do {
            guard try QueueSocket.withAddress(url.path, { bind(fd, $0, $1) }) == 0 else { throw QueueSocket.errno("bind") }
            // Nobody can connect before listen.
            guard chmod(url.path, 0o600) == 0 else { throw QueueSocket.errno("права сокета") }
            guard listen(fd, 16) == 0 else { throw QueueSocket.errno("listen") }
        } catch {
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: accepting)
        s.setEventHandler { [weak self] in self?.acceptOne(fd) }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    public func stop() {
        if let source {
            source.cancel()
            self.source = nil
            unlink(url.path)
        }
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    private func acceptOne(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else {
            // Out of descriptors: the listener stays readable, don't spin.
            if Darwin.errno != EAGAIN { usleep(50_000) }
            return
        }
        QueueSocket.prepare(fd)
        // Accepted sockets inherit O_NONBLOCK.
        _ = fcntl(fd, F_SETFL, 0)
        QueueSocket.timeout(fd, read: 5, write: 5)
        guard peerUID(fd) == getuid() else {
            Log.queue.logger.info("tt queue: connection of another user rejected")
            close(fd)
            return
        }
        guard lock.withLock({ connections < Self.maxConnections ? (connections += 1) : nil }) != nil else {
            close(fd)
            return
        }
        working.async { [self] in
            serve(fd)
            close(fd)
            lock.withLock { connections -= 1 }
        }
    }

    private func serve(_ fd: Int32) {
        let response: QueueResponse
        do {
            response = handler(try QueueRequest.decode(QueueSocket.receive(fd, limit: QueueProtocol.maxRequest)))
        } catch {
            response = QueueResponse(error: error as? QueueFailure ?? QueueFailure(.io, error.localizedDescription))
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        if data.count > QueueProtocol.maxResponse {
            guard let d = try? JSONEncoder().encode(QueueResponse(error: QueueFailure(.io, "ответ слишком большой"))) else { return }
            data = d
        }
        // The client may be gone; the operation itself is done either way.
        try? QueueSocket.send(data, to: fd)
    }
}

public struct QueueSocketClient: Sendable {
    public var url: URL
    public var timeout: Int
    var peerUID: @Sendable (Int32) -> uid_t?

    public init(url: URL, timeout: Int = 60, peerUID: @escaping @Sendable (Int32) -> uid_t? = QueueSocket.peerUID) {
        self.url = url
        self.timeout = timeout
        self.peerUID = peerUID
    }

    public func send(_ request: QueueRequest) throws -> QueueResponse {
        // Before connecting: the server would drop it, and that looks like an unknown outcome.
        let body = try JSONEncoder().encode(request)
        guard body.count <= QueueProtocol.maxRequest else {
            throw QueueFailure(.usage, "запрос слишком большой: \(body.count) байт, предел \(QueueProtocol.maxRequest)")
        }
        let fd = try QueueSocket.make()
        defer { close(fd) }
        // A request bigger than the socket buffer is written only as the server reads it: the same wait as for the answer.
        QueueSocket.timeout(fd, read: timeout, write: timeout)
        var code: Int32 = 0
        let r = try QueueSocket.withAddress(url.path) { a, n in
            let r = connect(fd, a, n)
            code = Darwin.errno
            return r
        }
        guard r == 0 else {
            if code == ENOENT || code == ECONNREFUSED || code == ENOTDIR {
                throw QueueFailure(.unavailable, "TrackTasks не запущен: открой приложение и повтори")
            }
            throw QueueFailure(.unavailable, "нет связи с TrackTasks (\(String(cString: strerror(code)))): \(url.path)")
        }
        guard peerUID(fd) == getuid() else {
            throw QueueFailure(.unavailable, "сокет принадлежит другому пользователю: \(url.path)")
        }
        let data: Data
        do {
            try QueueSocket.send(body, to: fd)
            data = try QueueSocket.receive(fd, limit: QueueProtocol.maxResponse)
        } catch {
            throw QueueFailure(.unavailable, "ответ TrackTasks не получен; команда могла выполниться, проверь tt queue list")
        }
        struct Head: Decodable { var `protocol`: Int }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.protocol == QueueProtocol.version,
              let response = try? JSONDecoder().decode(QueueResponse.self, from: data) else {
            throw QueueFailure(.version, "ответ TrackTasks другой версии")
        }
        if let e = response.error { throw e }
        return response
    }
}
