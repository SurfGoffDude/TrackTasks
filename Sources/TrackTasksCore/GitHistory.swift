import Foundation

/// Запуск git для экрана истории: байтовый ввод и вывод. Всё синхронно — вызывать не на главном потоке.
public enum GitRun {
    public typealias Runner = Checkpoints.Runner
    /// git, который ходит в сеть (таймаут, без запроса пароля).
    public typealias Network = (_ args: [String], _ dir: URL) -> DiffReject.Output

    public struct Failure: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Чтение не берёт замок индекса.
    static func read(_ args: [String], _ dir: URL, _ git: Runner) -> DiffReject.Output {
        git(args, dir, ["GIT_OPTIONAL_LOCKS": "0"], nil)
    }

    static func line(_ args: [String], _ dir: URL, _ git: Runner) -> String? {
        let o = read(args, dir, git)
        return o.ok ? o.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    public static func message(_ o: DiffReject.Output) -> String {
        for t in [o.err, o.text] {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "git завершился с ошибкой"
    }

    static func hasHead(_ dir: URL, _ git: Runner) -> Bool {
        read(["rev-parse", "--verify", "-q", "HEAD^{commit}"], dir, git).ok
    }
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public struct Label: Hashable, Sendable {
        public enum Kind: Sendable { case head, branch, remote, tag }
        public var kind: Kind
        public var name: String
    }
    public var id: String
    public var parents: [String]
    public var author: String
    public var date: Date
    public var subject: String
    public var labels: [Label]
    public var isMerge: Bool { parents.count > 1 }
}

/// Одна строка графа. Дорожки не сдвигаются: линия, которая здесь не начинается и не кончается, идёт прямо вниз.
public struct GitGraphRow: Equatable, Sendable {
    public struct Edge: Hashable, Sendable {
        public var lane: Int
        public var parent: String
    }
    /// Дорожка самого коммита.
    public var column: Int
    /// Дорожки сверху, которые приходят в коммит.
    public var incoming: [Int]
    /// Линии вниз, к родителям.
    public var outgoing: [Edge]
    /// Линии мимо коммита.
    public var passing: [Int]
    public var width: Int { ((incoming + passing + outgoing.map(\.lane) + [column]).max() ?? 0) + 1 }
}

public enum GitHistory {
    public static let page = 300

    public struct Page: Sendable {
        public var commits: [GitCommit] = []
        public var rows: [GitGraphRow] = []
        public var more = false
        public var error: String?
        public init() {}
    }

    /// Ветки, удалённые ветки, теги и HEAD; не `--all`, иначе видны снимки `refs/tracktasks/checkpoints`.
    public static func load(_ dir: URL, limit: Int = page, git: GitRun.Runner) -> Page {
        var page = Page()
        var args = ["log", "--topo-order", "-z", "--no-color", "--no-show-signature", "--no-patch", "--encoding=UTF-8",
                    "--decorate=full", "--decorate-refs=HEAD", "--decorate-refs=refs/heads/", "--decorate-refs=refs/remotes/",
                    "--decorate-refs=refs/tags/", "-n", "\(limit + 1)",
                    "--format=%H%x00%P%x00%an%x00%ct%x00%D%x00%s", "--branches", "--remotes", "--tags"]
        if GitRun.hasHead(dir, git) { args.append("HEAD") }
        let o = GitRun.read(args + ["--"], dir, git)
        guard o.ok else {
            page.error = GitRun.message(o)
            return page
        }
        let all = parse(o.out)
        page.more = all.count > limit
        page.commits = Array(all.prefix(limit))
        page.rows = graph(page.commits)
        return page
    }

    static func parse(_ out: Data) -> [GitCommit] {
        let f = out.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, to: f.count - 5, by: 6).map { i in
            GitCommit(id: f[i], parents: f[i + 1].split(separator: " ").map(String.init), author: f[i + 2],
                      date: Date(timeIntervalSince1970: TimeInterval(f[i + 3]) ?? 0), subject: f[i + 5],
                      labels: labels(f[i + 4]))
        }
    }

    static func labels(_ s: String) -> [GitCommit.Label] {
        s.components(separatedBy: ", ").flatMap { part -> [GitCommit.Label] in
            if part == "HEAD" { return [.init(kind: .head, name: "HEAD")] }
            if part.hasPrefix("HEAD -> ") {
                return [.init(kind: .head, name: "HEAD")] + labels(String(part.dropFirst(8)))
            }
            for (p, kind) in [("tag: refs/tags/", GitCommit.Label.Kind.tag), ("refs/heads/", .branch), ("refs/remotes/", .remote)]
            where part.hasPrefix(p) {
                return [.init(kind: kind, name: String(part.dropFirst(p.count)))]
            }
            return []
        }
    }

    /// Коммиты — от детей к родителям (`--topo-order`). Линии к незагруженным родителям уходят вниз за последнюю строку.
    public static func graph(_ commits: [GitCommit]) -> [GitGraphRow] {
        /// Какой коммит ждёт дорожка.
        var lanes: [String?] = []
        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }
        return commits.map { c in
            let incoming = lanes.indices.filter { lanes[$0] == c.id }
            let passing = lanes.indices.filter { lanes[$0] != nil && lanes[$0] != c.id }
            let column = incoming.first ?? freeLane()
            for i in incoming { lanes[i] = nil }
            var outgoing: [GitGraphRow.Edge] = []
            for p in c.parents where !outgoing.contains(where: { $0.parent == p }) {
                var lane = lanes.firstIndex(of: p)
                if lane == nil { lane = outgoing.isEmpty ? column : freeLane() }
                lanes[lane!] = p
                outgoing.append(.init(lane: lane!, parent: p))
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            return GitGraphRow(column: column, incoming: incoming, outgoing: outgoing, passing: passing)
        }
    }

    /// С чем сравнивать коммит: первый родитель, у корневого — пустое дерево (его хеш зависит от формата репозитория).
    public static func base(of c: GitCommit, in dir: URL, git: GitRun.Runner) -> String? {
        c.parents.first ?? GitRun.line(["hash-object", "-t", "tree", "/dev/null"], dir, git)
    }
}
