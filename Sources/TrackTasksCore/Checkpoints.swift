import Foundation

/// Снимки worktree перед ходами агента: дерево собирается во временном индексе и хранится коммитом под своей ссылкой.
/// Ветка, HEAD и индекс worktree не меняются; основная папка не снимается и не восстанавливается.
/// Игнорируемые git файлы в снимок не входят и при откате остаются как есть.
/// Синхронно — вызывать не на главном потоке.
public enum Checkpoints {
    public typealias Output = DiffReject.Output
    public typealias Runner = (_ args: [String], _ dir: URL, _ env: [String: String], _ input: Data?) -> Output

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Worktree задачи.
    public struct Site: Sendable {
        public var folder: URL
        public var branch: String
        /// Имена в корне, куда трекер сам положил ссылки на зависимости: в снимок не входят.
        public var links: Set<String>
        public init(folder: URL, branch: String, links: Set<String> = []) {
            self.folder = folder; self.branch = branch; self.links = links
        }
    }

    public enum Kind: String, Codable, Sendable { case turn, rollback }

    /// Что сохраняется в сообщении коммита снимка.
    public struct Meta: Codable, Equatable, Sendable {
        public var kind: Kind
        public var label: String
        public var date: Date
        /// Сессия, которую продолжал ход, и последняя реплика агента в ней. nil — ход начинал разговор.
        public var session: String?
        public var point: String?
        /// Общий для снимков, сделанных разом в нескольких репозиториях задачи.
        public var turn: String?
        public init(kind: Kind, label: String, date: Date = Date(), session: String? = nil, point: String? = nil, turn: String? = nil) {
            self.kind = kind; self.label = label; self.date = date; self.session = session; self.point = point; self.turn = turn
        }
        /// Разговор можно вернуть к этому месту: он ещё не начинался или известна точка.
        public var canRewind: Bool { session == nil || point != nil }
    }

    public struct Checkpoint: Identifiable, Equatable, Sendable {
        public var ref: String
        public var oid: String
        public var number: Int
        public var meta: Meta
        public var id: String { ref }
    }

    public struct Restored: Sendable {
        /// Состояние до отката.
        public var before: Checkpoint
        /// Код снова совпадает с последним коммитом ветки.
        public var matchesHead: Bool
    }

    // MARK: Действия

    @discardableResult
    public static func create(_ s: Site, _ meta: Meta, git: Runner) throws -> Checkpoint {
        try check(s, git)
        return try withIndex(s, git) { index in
            try stage(s, index, git)
            return try store(s, index, meta, git)
        }
    }

    /// Снимки ветки, от старых к новым. `dir` — любая папка репозитория.
    public static func list(branch: String, in dir: URL, git: Runner) throws -> [Checkpoint] {
        guard !branch.isEmpty else { return [] }
        let prefix = self.prefix(branch)
        let o = git(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(contents)%01", prefix], dir, [:], nil)
        guard o.ok else { throw failure(o) }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return o.out.split(separator: 1).compactMap { rec -> Checkpoint? in
            let f = rec.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { return nil }
            let ref = String(decoding: f[0], as: UTF8.self).trimmingCharacters(in: .newlines)
            // Ветка «a/b» не должна попасть в список ветки «a».
            guard ref.hasPrefix(prefix), let n = Int(ref.dropFirst(prefix.count)),
                  let brace = f[2].firstIndex(of: UInt8(ascii: "{")),
                  let meta = try? dec.decode(Meta.self, from: Data(f[2][brace...])) else { return nil }
            return Checkpoint(ref: ref, oid: String(decoding: f[1], as: UTF8.self), number: n, meta: meta)
        }.sorted { $0.number < $1.number }
    }

    /// Дерево текущего состояния без ссылки — для сравнения со снимком.
    public static func currentTree(_ s: Site, git: Runner) throws -> String {
        try check(s, git)
        return try withIndex(s, git) { index in
            try stage(s, index, git)
            return try text(["write-tree"], s.folder, index, git)
        }
    }

    /// То же для любой папки, и основной: индекс временный, ссылок нет, файлы не меняются.
    public static func folderTree(_ folder: URL, git: Runner) throws -> String {
        let s = Site(folder: folder, branch: "")
        return try withIndex(s, git) { index in
            try stage(s, index, git)
            return try text(["write-tree"], folder, index, git)
        }
    }

    /// Возвращает файлы worktree к снимку. Сначала снимает текущее состояние (`before`), поэтому откат обратим.
    /// До записи файлов любая ошибка ничего не меняет; файлы, изменённые во время отката, git не перезапишет.
    public static func restore(_ s: Site, to target: Checkpoint, before meta: Meta, git: Runner) throws -> Restored {
        try check(s, git)
        for h in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        where git(["rev-parse", "-q", "--verify", h], s.folder, [:], nil).ok {
            throw Failure("В worktree не завершено слияние или перенос коммита — закончи или отмени его в терминале")
        }
        return try withIndex(s, git) { index in
            try stage(s, index, git)
            let want = Set(try paths(["ls-tree", "-r", "-z", "--name-only", target.oid], s.folder, [:], git))
            try stageHidden(want, s, index, git)
            let saved = try store(s, index, meta, git)

            let have = Set(try paths(["ls-files", "--cached", "-z"], s.folder, index, git))
            let keep = try ignored(Array(have.subtracting(want)), by: target.oid, s, git)
            let tree = try targetTree(target.oid, keep: keep, from: saved.oid, s, git)

            let r = run(["read-tree", "-m", "-u", saved.oid, tree], s.folder, index, nil, git)
            guard r.ok else {
                throw Failure("Откат не выполнен: \(failure(r).message)\nСостояние до отката — в чекпоинте №\(saved.number).")
            }
            let head = try text(["rev-parse", "HEAD^{tree}"], s.folder, [:], git)
            return Restored(before: saved, matchesHead: head == tree)
        }
    }

    /// Убирает все снимки ветки. Объекты потом удалит `git gc`.
    public static func removeAll(branch: String, in dir: URL, git: Runner) {
        let refs = (try? list(branch: branch, in: dir, git: git))?.map(\.ref) ?? []
        guard !refs.isEmpty else { return }
        _ = run(["update-ref", "--stdin"], dir, [:], Data(refs.map { "delete \($0)\n" }.joined().utf8), git)
    }

    // MARK: Снимок

    static func prefix(_ branch: String) -> String { "refs/tracktasks/checkpoints/\(branch)/" }

    /// Только связанный worktree на своей ветке: основную папку не трогаем.
    static func check(_ s: Site, _ git: Runner) throws {
        let head = git(["symbolic-ref", "--short", "-q", "HEAD"], s.folder, [:], nil)
        guard !s.branch.isEmpty, head.text.trimmingCharacters(in: .whitespacesAndNewlines) == s.branch else {
            throw Failure("Worktree удалён или в нём не ветка \(s.branch)")
        }
        let dir = try text(["rev-parse", "--path-format=absolute", "--git-dir"], s.folder, [:], git)
        let common = try text(["rev-parse", "--path-format=absolute", "--git-common-dir"], s.folder, [:], git)
        guard dir != common else { throw Failure("Чекпоинты делаются только в worktree — основная папка не трогается") }
    }

    /// Временный индекс — копия настоящего: дата файла сохраняется, иначе git примет свежие правки за неизменённые.
    static func withIndex<T>(_ s: Site, _ git: Runner, _ body: ([String: String]) throws -> T) throws -> T {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("index")
        let real = try text(["rev-parse", "--path-format=absolute", "--git-path", "index"], s.folder, [:], git)
        if FileManager.default.fileExists(atPath: real) {
            do { try FileManager.default.copyItem(atPath: real, toPath: copy.path) } catch {
                throw Failure("Не удалось скопировать индекс git: \(error.localizedDescription)")
            }
        }
        return try body(["GIT_INDEX_FILE": copy.path])
    }

    static func stage(_ s: Site, _ index: [String: String], _ git: Runner) throws {
        let others = try paths(["ls-files", "--others", "--exclude-standard", "-z"], s.folder, index, git)
        // Вложенный репозиторий (путь с «/») git сохранил бы ссылкой без содержимого.
        let skip = others.filter {
            $0.hasSuffix("/") || (s.links.contains($0) && isLink(s.folder.appendingPathComponent($0).path))
        }
        try ok(["add", "-A", "--", "."] + skip.map { ":(top,exclude,literal)" + ($0.hasSuffix("/") ? String($0.dropLast()) : $0) },
               s.folder, index, nil, git)
    }

    /// Файлы, которые откат перезапишет, а обычный снимок не видит: сейчас они игнорируются.
    private static func stageHidden(_ want: Set<String>, _ s: Site, _ index: [String: String], _ git: Runner) throws {
        let have = Set(try paths(["ls-files", "--cached", "-z"], s.folder, index, git))
        var add = Set<String>(), dirs: [String] = []
        for p in want.subtracting(have) {
            var at = ""
            for part in p.split(separator: "/") {
                at += (at.isEmpty ? "" : "/") + part
                var st = stat()
                guard lstat(s.folder.appendingPathComponent(at).path, &st) == 0 else { break }
                if st.st_mode & S_IFMT == S_IFDIR {
                    if at == p { dirs.append(p) }
                    continue
                }
                if !have.contains(at) { add.insert(at) }
                break
            }
        }
        for d in dirs {
            let inside = try paths(["--literal-pathspecs", "ls-files", "--others", "-z", "--", d], s.folder, index, git)
            if !inside.isEmpty { throw Failure("На месте файла \(d) теперь папка с файлами вне git — убери её и повтори") }
        }
        guard !add.isEmpty else { return }
        try ok(["--literal-pathspecs", "add", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"], s.folder, index,
               Data(add.sorted().joined(separator: "\0").utf8), git)
    }

    private static func store(_ s: Site, _ index: [String: String], _ meta: Meta, _ git: Runner) throws -> Checkpoint {
        let tree = try text(["write-tree"], s.folder, index, git)
        let head = try text(["rev-parse", "--verify", "HEAD^{commit}"], s.folder, [:], git)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let json = try? enc.encode(meta) else { throw Failure("Не удалось записать чекпоинт") }
        let o = try ok(["-c", "user.name=TrackTasks", "-c", "user.email=tracktasks@localhost", "-c", "i18n.commitEncoding=UTF-8",
                        "commit-tree", tree, "-p", head], s.folder, [:], Data("TrackTasks checkpoint\n\n".utf8) + json, git)
        let oid = trim(o)
        let n = (try list(branch: s.branch, in: s.folder, git: git).last?.number ?? 0) + 1
        let ref = prefix(s.branch) + String(format: "%06d", n)
        // Пустое старое значение: ссылка не должна существовать.
        try ok(["update-ref", ref, oid, ""], s.folder, [:], nil, git)
        return Checkpoint(ref: ref, oid: oid, number: n, meta: meta)
    }

    // MARK: Откат

    /// Какие из путей игнорировались бы в снимке: они могли лежать там и тогда, поэтому их не удаляем.
    private static func ignored(_ candidates: [String], by oid: String, _ s: Site, _ git: Runner) throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rules = try paths(["ls-tree", "-r", "-z", "--name-only", oid], s.folder, [:], git)
            .filter { $0 == ".gitignore" || $0.hasSuffix("/.gitignore") }
        for p in rules {
            let blob = git(["cat-file", "blob", "\(oid):\(p)"], s.folder, [:], nil)
            let url = dir.appendingPathComponent(p)
            guard blob.ok else { throw failure(blob) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.out.write(to: url)
        }
        let gitDir = try text(["rev-parse", "--path-format=absolute", "--git-dir"], s.folder, [:], git)
        let o = run(["--git-dir=\(gitDir)", "--work-tree=\(dir.path)", "check-ignore", "--no-index", "-z", "--stdin"],
                    dir, [:], Data(candidates.joined(separator: "\0").utf8), git)
        // 1 — ничего не игнорируется.
        guard o.status == 0 || o.status == 1 else { throw failure(o) }
        return split(o.out)
    }

    private static func targetTree(_ oid: String, keep: [String], from saved: String, _ s: Site, _ git: Runner) throws -> String {
        guard !keep.isEmpty else { return try text(["rev-parse", "\(oid)^{tree}"], s.folder, [:], git) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = ["GIT_INDEX_FILE": dir.appendingPathComponent("index").path]
        try ok(["read-tree", oid], s.folder, index, nil, git)
        let kept = Set(keep)
        let o = try ok(["ls-tree", "-r", "-z", saved], s.folder, [:], nil, git)
        // «mode type oid\tpath» — формат, который принимает --index-info.
        let lines = split(o.out).filter { kept.contains(String($0.drop { $0 != "\t" }.dropFirst())) }
        try ok(["update-index", "-z", "--index-info"], s.folder, index, Data(lines.map { $0 + "\0" }.joined().utf8), git)
        // --index-info молча заменяет конфликтующие пути: снимок не должен потерять файлы.
        let have = Set(try paths(["ls-files", "--cached", "-z"], s.folder, index, git))
        let want = try paths(["ls-tree", "-r", "-z", "--name-only", oid], s.folder, [:], git)
        if let lost = want.first(where: { !have.contains($0) }) {
            throw Failure("На месте \(lost) лежит файл, который снимок игнорирует, — убери его и повтори")
        }
        return try text(["write-tree"], s.folder, index, git)
    }

    // MARK: git

    /// Без хуков, fsmonitor и остановок на CRLF.
    private static let config = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.safecrlf=false"]

    static func run(_ args: [String], _ dir: URL, _ env: [String: String], _ input: Data?, _ git: Runner) -> Output {
        git(config + args, dir, env, input)
    }

    @discardableResult
    static func ok(_ args: [String], _ dir: URL, _ env: [String: String], _ input: Data?, _ git: Runner) throws -> Output {
        let o = run(args, dir, env, input, git)
        guard o.ok else { throw failure(o) }
        return o
    }

    static func text(_ args: [String], _ dir: URL, _ env: [String: String], _ git: Runner) throws -> String {
        trim(try ok(args, dir, env, nil, git))
    }

    static func paths(_ args: [String], _ dir: URL, _ env: [String: String], _ git: Runner) throws -> [String] {
        split(try ok(args, dir, env, nil, git).out)
    }

    private static func split(_ d: Data) -> [String] { d.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } }
    static func trim(_ o: Output) -> String { o.text.trimmingCharacters(in: .newlines) }

    static func failure(_ o: Output) -> Failure {
        let t = o.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure(t.isEmpty ? "git завершился с ошибкой" : t)
    }

    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tracktasks-checkpoint-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch {
            throw Failure("Не удалось создать временную папку: \(error.localizedDescription)")
        }
        return u
    }
}

/// Место в разговоре, с которого его продолжит новая сессия. Файлы сессий не правятся.
public struct SessionRewind: Codable, Equatable, Sendable {
    /// nil — разговор начинается заново.
    public var session: String?
    public var point: String?
    public init(session: String?, point: String?) { self.session = session; self.point = point }
}
