import Foundation
import Network

public struct EventRequest: Equatable, Sendable {
    /// Random part of the address.
    public var id: String
    public var headers: [String: String]
    public var body: Data
}

public struct EventResponse: Equatable, Sendable {
    public var status: Int
    public var text: String
    public init(_ status: Int, _ text: String) { self.status = status; self.text = text }
    /// The same for an unknown address and for a wrong signature.
    public static let denied = EventResponse(401, "отказано")
}

/// The only request accepted: `POST /hook/<id>` with `Content-Length`. Anything unusual is refused, not interpreted.
public struct EventHTTP {
    public enum Step: Equatable { case more, request(EventRequest), refuse(EventResponse) }

    static let maxHead = 16 << 10
    static let maxBody = 256 << 10
    /// Headers with a meaning here: repeated ones are refused.
    static let single: Set<String> = ["host", "content-length", "x-tracktasks-timestamp", "x-tracktasks-nonce", "x-tracktasks-signature",
                                      "x-hub-signature-256", "x-github-event"]
    private var buffer = Data()
    private var head: (id: String, headers: [String: String], length: Int)?
    public init() {}

    public mutating func feed(_ data: Data) -> Step {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > Self.maxHead ? .refuse(.init(431, "слишком большие заголовки")) : .more
            }
            guard end.upperBound - buffer.startIndex <= Self.maxHead else { return .refuse(.init(431, "слишком большие заголовки")) }
            if let refused = parse(Data(buffer[buffer.startIndex..<end.lowerBound])) { return .refuse(refused) }
            buffer = Data(buffer[end.upperBound...])
        }
        guard let head else { return .refuse(.init(400, "неверный запрос")) }
        if buffer.count > head.length { return .refuse(.init(400, "лишние данные после тела")) }
        return buffer.count < head.length ? .more : .request(EventRequest(id: head.id, headers: head.headers, body: buffer))
    }

    private mutating func parse(_ data: Data) -> EventResponse? {
        let bad = EventResponse(400, "неверный запрос")
        // Control bytes (a lone CR or LF too) and non-ASCII have no place in headers.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        var text: [String] = []
        for (i, l) in lines.enumerated() {
            var l = l
            if i < lines.count - 1 {
                guard l.last == 13 else { return bad }
                l = l.dropLast()
            }
            guard l.allSatisfy({ (32...126).contains($0) || $0 == 9 }), let s = String(bytes: l, encoding: .ascii) else { return bad }
            text.append(s)
        }
        let first = text[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { return bad }
        var headers: [String: String] = [:]
        for l in text.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { return bad }
            let name = l[..<colon].lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return bad }
            if headers[name] != nil, Self.single.contains(name) { return bad }
            headers[name] = l[l.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        guard headers["transfer-encoding"] == nil else { return bad }
        // A page in a browser is not a sender of events.
        guard headers["origin"] == nil, let host = headers["host"], Self.isLocal(host) else { return .init(403, "чужой Host или Origin") }
        guard first[0] == "POST" else { return .init(405, "только POST") }
        guard let raw = headers["content-length"], !raw.isEmpty, raw.utf8.count <= 10, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(raw) else { return .init(411, "нужен Content-Length") }
        guard length <= Self.maxBody else { return .init(413, "тело больше 256 КБ") }
        guard first[1].hasPrefix("/hook/") else { return .denied }
        let id = String(first[1].dropFirst(6))
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .denied }
        head = (id, headers, length)
        return nil
    }

    private static func isLocal(_ host: String) -> Bool {
        let parts = host.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard let name = parts.first, name == "127.0.0.1" || name == "localhost" else { return false }
        return parts.count == 1 || (parts.count == 2 && UInt16(parts[1]) != nil)
    }
}

/// HTTP on 127.0.0.1 only. One request a connection.
public final class EventServer: @unchecked Sendable {
    public typealias Handler = @Sendable (EventRequest) async -> EventResponse
    public enum Status: Equatable, Sendable { case ready(UInt16), failed(String) }

    static let maxConnections = 16
    private let queue = DispatchQueue(label: "TrackTasks.events")
    private let timeout: TimeInterval
    private let handler: Handler
    private var listener: NWListener?
    private var open: [ObjectIdentifier: NWConnection] = [:]

    public init(timeout: TimeInterval = 10, handler: @escaping Handler) {
        self.timeout = timeout
        self.handler = handler
    }

    /// `port` 0 — any free one (tests). `status` is called on a background queue.
    public func start(port: UInt16, status: @escaping @Sendable (Status) -> Void) {
        queue.async { [self] in
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
            p.includePeerToPeer = false
            let l: NWListener
            do { l = try NWListener(using: p) } catch { return status(.failed(error.localizedDescription)) }
            listener = l
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self, weak l] s in
                switch s {
                case .ready: status(.ready(l?.port?.rawValue ?? port))
                // No other port instead: the address is already given out.
                case .waiting(let e), .failed(let e):
                    l?.cancel()
                    self?.listener = nil
                    status(.failed(e.localizedDescription))
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            open.values.forEach { $0.cancel() }
            open = [:]
        }
    }

    private func serve(_ c: NWConnection) {
        guard listener != nil, open.count < Self.maxConnections else { return c.cancel() }
        let key = ObjectIdentifier(c)
        open[key] = c
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed: c.cancel()
            case .cancelled:
                self?.open[key] = nil
                c.stateUpdateHandler = nil
            default: break
            }
        }
        c.start(queue: queue)
        // The whole exchange, however slowly the other side sends or reads.
        queue.asyncAfter(deadline: .now() + timeout) { [weak c] in c?.cancel() }
        read(c, EventHTTP())
    }

    private func read(_ c: NWConnection, _ http: EventHTTP) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, end, error in
            guard let self else { return c.cancel() }
            var http = http
            switch http.feed(data ?? Data()) {
            case .request(let r):
                Task {
                    let out = await self.handler(r)
                    self.queue.async { Self.send(out, c) }
                }
            case .refuse(let out): Self.send(out, c)
            case .more:
                if end || error != nil { c.cancel() } else { self.read(c, http) }
            }
        }
    }

    private static func send(_ r: EventResponse, _ c: NWConnection) {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 409: "Conflict", 429: "Too Many Requests", 503: "Service Unavailable"][r.status]
            ?? (r.status < 300 ? "OK" : "Error")
        let body = Data((r.text + "\n").utf8)
        let head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
