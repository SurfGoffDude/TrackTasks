import Foundation

/// Отклонение файла или куска diff в worktree: обратный патч, который строит сам git.
/// Раздел «Ветка» дополнительно коммитится в ветку worktree, иначе слияние вернуло бы отклонённое.
/// Основная папка только читается. Синхронно — вызывать не на главном потоке.
public enum DiffReject {
    /// Сырые байты: патч не должен пострадать от кодировки файла.
    public struct Output: Sendable {
        public var status: Int32
        public var out: Data
        public var err: String
        public var ok: Bool { status == 0 }
        public var text: String { String(decoding: out, as: UTF8.self) }
        public init(status: Int32, out: Data, err: String = "") {
            self.status = status; self.out = out; self.err = err
        }
    }
    public typealias Runner = (_ args: [String], _ dir: URL, _ input: Data?) -> Output

    public struct Failure: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// Последнее отклонение. Лежит в служебной папке git этого worktree и исчезает вместе с ним.
    public struct Undo: Codable, Sendable {
        public var kind: DiffSection.Kind
        public var label: String
        var paths: [String]
        var patch: Data
        /// Содержимое файлов сразу после отклонения: отмена накладывается только на него.
        var states: [String: String]
    }

    // MARK: Действия

    /// `hunk` — номер куска в `entry.file.hunks`, nil — весь файл.
    public static func reject(_ s: DiffSource, _ kind: DiffSection.Kind, _ entry: DiffSection.Entry,
                              hunk: Int? = nil, git: Runner) throws {
        try checkFolder(s, kind, git)
        let f = entry.file
        // Новый и удалённый файл — всегда один кусок, он же весь файл.
        let hunk = f.status == .added || f.status == .deleted ? nil : hunk
        let patch = try entry.untracked ? untrackedPatch(s, f, git) : trackedPatch(s, kind, f, hunk, git)
        let paths = hunk != nil ? [f.path] : Array(Set([f.oldPath, f.newPath].compactMap { $0 })).sorted()
        let label = f.path + (hunk.map { " · кусок \($0 + 1)" } ?? "")

        if kind == .branch { try checkClean(paths, s, git) }
        try apply(patch, reverse: true, check: true, kind, s, git)

        let store = try undoURL(s, git)
        let previous = try? Data(contentsOf: store)
        func restoreRecord() {
            if let previous { try? previous.write(to: store, options: .atomic) } else { try? FileManager.default.removeItem(at: store) }
        }
        var undo = Undo(kind: kind, label: label, paths: paths, patch: patch, states: [:])
        // Запись до правки: если её не сохранить, отклонение нельзя будет отменить.
        try save(undo, store)
        do {
            try apply(patch, reverse: true, check: false, kind, s, git)
        } catch {
            restoreRecord()
            throw error
        }
        do {
            undo.states = states(paths, s.folder)
            try save(undo, store)
            if kind == .branch { try commit("TrackTasks: отклонено — \(label)", paths, s, git) }
        } catch {
            let back = Result { try apply(patch, reverse: false, check: false, kind, s, git) }
            if case .failure = back { throw Failure(text(error) + "\nВернуть файл не удалось — проверь worktree в терминале.") }
            restoreRecord()
            throw error
        }
        // Индекс мог помнить `git add`/`git mv` отклонённого файла.
        if kind == .working, hunk == nil, !entry.untracked {
            _ = git(["--literal-pathspecs", "reset", "-q", "HEAD", "--"] + paths, s.folder, nil)
        }
    }

    public static func last(_ s: DiffSource, git: Runner) -> Undo? {
        guard s.branch != nil, let u = try? undoURL(s, git), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Undo.self, from: d)
    }

    @discardableResult
    public static func undoLast(_ s: DiffSource, git: Runner) throws -> Undo {
        guard let u = last(s, git: git) else { throw Failure("Нечего отменять") }
        try checkFolder(s, u.kind, git)
        guard states(u.paths, s.folder) == u.states else {
            throw Failure("Файл изменился после отклонения — отмена невозможна: \(u.label)")
        }
        if u.kind == .branch { try checkClean(u.paths, s, git) }
        try apply(u.patch, reverse: false, check: true, u.kind, s, git)
        try apply(u.patch, reverse: false, check: false, u.kind, s, git)
        if u.kind == .branch {
            do {
                try commit("TrackTasks: отмена отклонения — \(u.label)", u.paths, s, git)
            } catch {
                let back = Result { try apply(u.patch, reverse: true, check: false, u.kind, s, git) }
                if case .failure = back { throw Failure(text(error) + "\nВернуть файл не удалось — проверь worktree в терминале.") }
                throw error
            }
        }
        if let store = try? undoURL(s, git) { try? FileManager.default.removeItem(at: store) }
        return u
    }

    // MARK: Патч

    private static func trackedPatch(_ s: DiffSource, _ kind: DiffSection.Kind, _ f: DiffFile, _ hunk: Int?,
                                     _ git: Runner) throws -> Data {
        let dir: URL, range: String
        if kind == .branch, let b = s.branch { dir = b.main; range = b.range } else { dir = s.folder; range = "HEAD" }
        let paths = Array(Set([f.oldPath, f.newPath].compactMap { $0 })).sorted()
        func sections(_ extra: [String]) throws -> [RawFile] {
            let o = git(["--literal-pathspecs"] + DiffCollector.diffArgs + extra + [range, "--"] + paths, dir, nil)
            guard o.ok else { throw failure(o) }
            return split(o.out)
        }
        let fresh = try sections([])
        guard let i = fresh.firstIndex(where: { raw in
            DiffParser.parse(String(decoding: raw.all, as: UTF8.self), limits: DiffCollector.limits)
                .files.first.map { same($0, f) } ?? false
        }) else { throw stale }
        try refuseSubmodule(fresh[i].header)
        guard let hunk else {
            // Двоичные файлы и полные хеши — только с --binary.
            let full = try sections(["--binary", "-U3"])
            guard full.count == fresh.count else { throw stale }
            return full[i].all
        }
        let parsed = DiffParser.parse(String(decoding: fresh[i].all, as: UTF8.self), limits: .unlimited).files.first
        guard let parsed, f.hunks.indices.contains(hunk), parsed.hunks.indices.contains(hunk),
              fresh[i].hunks.indices.contains(hunk) else { throw stale }
        guard parsed.hunks[hunk] == f.hunks[hunk] else { throw Failure("Кусок показан не полностью — отклонить можно только файл") }
        return hunkPatch(path: f.path, parsed.hunks[hunk], body: fresh[i].hunks[hunk])
    }

    private static func untrackedPatch(_ s: DiffSource, _ f: DiffFile, _ git: Runner) throws -> Data {
        guard !f.path.hasSuffix("/") else { throw Failure("Вложенный репозиторий так отклонить нельзя") }
        let now = DiffCollector.untracked(f.path, in: s.folder, maxLines: DiffCollector.limits.maxLinesPerFile)
        guard same(now, f) else { throw stale }
        let o = git(["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--binary", "-U3",
                     "--src-prefix=a/", "--dst-prefix=b/", "--", "/dev/null", f.path], s.folder, nil)
        // 1 — «есть различия».
        guard o.status == 0 || o.status == 1, !o.out.isEmpty else { throw failure(o) }
        return o.out
    }

    /// Патч из одного куска: без смены прав и переименования — их отклоняет только действие для файла.
    /// git ищет место куска по номеру строки результата. Остальные куски остаются, поэтому обе стороны
    /// получают номер из текущего файла — иначе среди одинаковых строк патч лёг бы не туда.
    static func hunkPatch(path: String, _ h: DiffHunk, body: Data) -> Data {
        let start = h.newCount > 0 ? h.newStart : h.newStart + 1
        let old = h.oldCount > 0 ? start : start - 1
        let a = quote("a/" + path), b = quote("b/" + path)
        var d = Data("diff --git \(a) \(b)\n--- \(a)\n+++ \(b)\n@@ -\(old),\(h.oldCount) +\(h.newStart),\(h.newCount) @@\n".utf8)
        d.append(body)
        return d
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for b in s.utf8 {
            switch b {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                let o = String(b, radix: 8)
                out += "\\" + String(repeating: "0", count: 3 - o.count) + o
            }
        }
        return out + "\""
    }

    struct RawFile {
        var header = Data()
        /// Тела кусков без строки `@@`.
        var hunks: [Data] = []
        var all = Data()
    }

    /// Режет вывод `git diff` на файлы и куски, не трогая байты.
    static func split(_ data: Data) -> [RawFile] {
        var files: [RawFile] = []
        var i = data.startIndex
        var oldLeft = 0, newLeft = 0
        while i < data.endIndex {
            let end = data[i...].firstIndex(of: 0x0A).map { $0 + 1 } ?? data.endIndex
            let line = data[i..<end]
            i = end
            let inside = oldLeft > 0 || newLeft > 0
            if !inside, line.starts(with: Data("diff --git ".utf8)) { files.append(RawFile()) }
            guard !files.isEmpty else { continue }
            let f = files.count - 1
            files[f].all.append(line)
            if inside || (line.first == 0x5C && !files[f].hunks.isEmpty) {
                files[f].hunks[files[f].hunks.count - 1].append(line)
                switch line.first {
                case 0x2B: newLeft -= 1
                case 0x2D: oldLeft -= 1
                case 0x5C: break
                default: oldLeft -= 1; newLeft -= 1
                }
            } else if line.starts(with: Data("@@ ".utf8)),
                      let h = DiffParser.parseHunkHeader(Substring(String(decoding: line, as: UTF8.self))) {
                files[f].hunks.append(Data())
                oldLeft = h.oldCount; newLeft = h.newCount
            } else {
                files[f].header.append(line)
            }
        }
        return files
    }

    /// Показанный файл и нынешний — одно и то же.
    private static func same(_ now: DiffFile, _ shown: DiffFile) -> Bool {
        guard now.oldPath == shown.oldPath, now.newPath == shown.newPath, now.status == shown.status,
              now.oldMode == shown.oldMode, now.newMode == shown.newMode else { return false }
        // Усечение зависит от соседних файлов: сравниваем хеши содержимого.
        if shown.truncated { return now.index == shown.index }
        return DiffCollector.fingerprint(now) == DiffCollector.fingerprint(shown)
    }

    private static func refuseSubmodule(_ header: Data) throws {
        let h = String(decoding: header, as: UTF8.self)
        if h.split(separator: "\n").contains(where: { ($0.hasPrefix("index ") || $0.contains("mode ")) && $0.hasSuffix(" 160000") }) {
            throw Failure("Подмодуль так отклонить нельзя")
        }
    }

    // MARK: git

    private static func checkFolder(_ s: DiffSource, _ kind: DiffSection.Kind, _ git: Runner) throws {
        guard let b = s.branch else { throw Failure("Отклонять можно только правки в worktree") }
        guard s.folder.standardizedFileURL.path != b.main.standardizedFileURL.path else {
            throw Failure("Отклонение не трогает основную папку")
        }
        let head = git(["symbolic-ref", "--short", "-q", "HEAD"], s.folder, nil)
        guard head.text.trimmingCharacters(in: .whitespacesAndNewlines) == b.name else {
            throw Failure("Worktree удалён или в нём не ветка \(b.name)")
        }
    }

    private static func checkClean(_ paths: [String], _ s: DiffSource, _ git: Runner) throws {
        let o = git(["--literal-pathspecs", "status", "--porcelain", "-z", "--untracked-files=all", "--"] + paths, s.folder, nil)
        guard o.ok else { throw failure(o) }
        guard o.out.isEmpty else {
            throw Failure("В файле есть незакоммиченные правки — сначала отклони или закоммить их: \(paths.joined(separator: ", "))")
        }
    }

    private static func apply(_ patch: Data, reverse: Bool, check: Bool, _ kind: DiffSection.Kind, _ s: DiffSource,
                              _ git: Runner) throws {
        var a = ["apply", "--whitespace=nowarn", "--no-ignore-whitespace"]
        if reverse { a.append("-R") }
        if kind == .branch { a.append("--index") }
        if check { a.append("--check") }
        let o = git(a + ["-"], s.folder, patch)
        guard o.ok else { throw Failure("Патч не применяется, ничего не изменено:\n" + failure(o).message) }
    }

    /// Только эти пути: остальное в индексе worktree не трогаем.
    private static func commit(_ message: String, _ paths: [String], _ s: DiffSource, _ git: Runner) throws {
        let o = git(["--literal-pathspecs", "commit", "--no-verify", "-q", "-m", message, "--only", "--"] + paths, s.folder, nil)
        guard o.ok else { throw Failure("Не удалось закоммитить в ветку:\n" + failure(o).message) }
    }

    private static let stale = Failure("Diff изменился с момента показа — обнови и попробуй ещё раз")

    private static func failure(_ o: Output) -> Failure {
        let t = o.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure(t.isEmpty ? "git завершился с ошибкой" : t)
    }

    private static func text(_ e: Error) -> String { (e as? Failure)?.message ?? e.localizedDescription }

    private static func undoURL(_ s: DiffSource, _ git: Runner) throws -> URL {
        let o = git(["rev-parse", "--git-path", "tracktasks-reject.json"], s.folder, nil)
        let p = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard o.ok, !p.isEmpty else { throw failure(o) }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : s.folder.appendingPathComponent(p)
    }

    private static func save(_ u: Undo, _ url: URL) throws {
        do { try JSONEncoder().encode(u).write(to: url, options: .atomic) } catch {
            throw Failure("Не удалось сохранить запись для отмены: \(error.localizedDescription)")
        }
    }

    private static func states(_ paths: [String], _ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        for p in paths {
            let path = dir.appendingPathComponent(p).path
            let data: Data
            if let t = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                data = Data(("link:" + t).utf8)
            } else if let d = FileManager.default.contents(atPath: path) {
                data = d
            } else {
                out[p] = "-"
                continue
            }
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            out[p] = "\(data.count)-" + String(h, radix: 16)
        }
        return out
    }
}
