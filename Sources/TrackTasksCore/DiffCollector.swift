import Foundation

/// Что показать на экране diff: правки папки и, для worktree, коммиты его ветки.
public struct DiffSource: Codable, Hashable, Sendable {
    public struct Branch: Codable, Hashable, Sendable {
        /// Основная папка проекта.
        public var main: URL
        /// Коммит, от которого создан worktree. Пусто — берётся точка расхождения с HEAD основной папки.
        public var base: String
        public var name: String
        public init(main: URL, base: String, name: String) {
            self.main = main; self.base = base; self.name = name
        }
        public var range: String { base.isEmpty ? "HEAD...\(name)" : "\(base)..\(name)" }
    }

    /// Сравнение двух снимков worktree (`Checkpoints`).
    public struct Span: Codable, Hashable, Sendable {
        public var from: String
        /// nil — текущее состояние папки: дерево подставляется перед загрузкой.
        public var to: String?
        public var title: String
        public init(from: String, to: String?, title: String) {
            self.from = from; self.to = to; self.title = title
        }
    }

    public var title: String
    /// Папка с незакоммиченными правками: worktree или основная.
    public var folder: URL
    public var branch: Branch?
    /// Job очереди, чьи изменения смотрим: ему уходят комментарии.
    public var jobID: UUID?

    public var span: Span?
    /// Ветка worktree, снимки которой сравниваются.
    public var spanBranch: String?

    public init(title: String, folder: URL, branch: Branch? = nil, jobID: UUID? = nil, span: Span? = nil, spanBranch: String? = nil) {
        self.title = title; self.folder = folder; self.branch = branch; self.jobID = jobID
        self.span = span; self.spanBranch = spanBranch
    }

    /// Ключ отметок «просмотрено».
    public var key: String { folder.path + "\n" + (span.map { "\($0.from)..\($0.to ?? "")" } ?? branch.map { $0.range } ?? "") }
}

public struct DiffSection: Sendable {
    public enum Kind: String, Codable, Sendable { case branch, working }
    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let file: DiffFile
        public let untracked: Bool
        /// Меняется вместе с содержимым: отметка «просмотрено» снимается, когда файл изменился.
        public let fingerprint: String
    }
    public var kind: Kind
    public var entries: [Entry] = []
    public var skippedFiles = 0
    public var truncated = false
    /// Почему раздел не удалось получить.
    public var error: String?

    public static func failed(_ error: String) -> DiffSection { DiffSection(kind: .branch, error: error) }
}

/// Собирает diff через переданный запуск git. Синхронно — вызывать не на главном потоке.
public enum DiffCollector {
    public struct Output: Sendable {
        public var ok: Bool
        public var out: String
        public var err: String
        /// Вывод обрезан по размеру.
        public var cut: Bool
        public init(ok: Bool, out: String, err: String = "", cut: Bool = false) {
            self.ok = ok; self.out = out; self.err = err; self.cut = cut
        }
    }
    public typealias Runner = (_ args: [String], _ dir: URL) -> Output

    public static let limits = DiffParser.Limits(maxLinesPerFile: 50_000, maxTotalLines: 200_000, maxFiles: 2_000)
    static let maxUntrackedBytes = 5_000_000

    /// Формат не зависит от настроек пользователя (noprefix, внешний diff, цвет).
    public static let diffArgs = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short",
                           "--src-prefix=a/", "--dst-prefix=b/", "-M", "--relative"]

    /// `skipUntracked` — имена в корне, которые положил сам трекер (ссылки на зависимости в worktree).
    public static func collect(_ s: DiffSource, skipUntracked: Set<String> = [], git: Runner) -> [DiffSection] {
        if let span = s.span {
            guard let to = span.to else { return [DiffSection(kind: .branch, error: "Не удалось получить текущее состояние")] }
            return [section(.branch, git(diffArgs + [span.from, to, "--"], s.folder))]
        }
        var out: [DiffSection] = []
        if let b = s.branch {
            out.append(section(.branch, git(diffArgs + [b.range, "--"], b.main)))
        }
        out.append(working(s.folder, skip: s.branch == nil ? [] : skipUntracked, git: git))
        return out
    }

    private static func working(_ dir: URL, skip: Set<String>, git: Runner) -> DiffSection {
        let inside = git(["rev-parse", "--is-inside-work-tree"], dir)
        guard inside.ok else {
            return DiffSection(kind: .working, error: message(inside))
        }
        var base = "HEAD"
        if !git(["rev-parse", "--verify", "-q", "HEAD"], dir).ok {
            // Репозиторий без коммитов: сравниваем с пустым деревом.
            base = git(["hash-object", "-t", "tree", "/dev/null"], dir).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var sec = section(.working, git(diffArgs + [base, "--"], dir))
        let others = git(["ls-files", "--others", "--exclude-standard", "-z"], dir)
        guard others.ok else {
            if sec.error == nil { sec.error = message(others) }
            return sec
        }
        var budget = limits.maxTotalLines
        for path in others.out.split(separator: "\0").map(String.init) where !skip.contains(path) {
            guard sec.entries.count < limits.maxFiles else {
                sec.skippedFiles += 1
                sec.truncated = true
                continue
            }
            let f = untracked(path, in: dir, maxLines: min(limits.maxLinesPerFile, budget))
            budget -= f.hunks.reduce(0) { $0 + $1.lines.count }
            budget = max(0, budget)
            if f.truncated { sec.truncated = true }
            sec.entries.append(entry(f, .working, untracked: true))
        }
        return sec
    }

    private static func message(_ o: Output) -> String {
        let t = o.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "git завершился с ошибкой" : t
    }

    private static func section(_ kind: DiffSection.Kind, _ o: Output) -> DiffSection {
        guard o.ok else { return DiffSection(kind: kind, error: message(o)) }
        let r = DiffParser.parse(o.out, limits: limits)
        return DiffSection(kind: kind, entries: r.files.map { entry($0, kind, untracked: false) },
                           skippedFiles: r.skippedFiles, truncated: r.truncated || o.cut)
    }

    private static func entry(_ f: DiffFile, _ kind: DiffSection.Kind, untracked: Bool) -> DiffSection.Entry {
        .init(id: kind.rawValue + ":" + f.path, file: f, untracked: untracked, fingerprint: fingerprint(f))
    }

    /// Новый файл, которого git ещё не знает, — тем же видом, что `git diff --no-index /dev/null <файл>`.
    static func untracked(_ path: String, in dir: URL, maxLines: Int) -> DiffFile {
        var f = DiffFile(oldPath: nil, newPath: path)
        f.status = .added
        let url = dir.appendingPathComponent(path)
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = a[.type] as? FileAttributeType else {
            f.truncated = true
            return f
        }
        let size = (a[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        f.index = "\(size)-\(mtime)"
        let data: Data
        switch type {
        case .typeSymbolicLink:
            f.newMode = "120000"
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            data = Data(target.utf8)
        case .typeRegular:
            let mode = (a[.posixPermissions] as? NSNumber)?.intValue ?? 0
            f.newMode = mode & 0o100 != 0 ? "100755" : "100644"
            guard size <= maxUntrackedBytes, let d = try? Data(contentsOf: url) else {
                f.truncated = true
                return f
            }
            data = d
        default: // вложенный репозиторий и прочее
            f.truncated = true
            return f
        }
        guard !data.isEmpty else { return f }
        if data.prefix(8_000).contains(0) {
            f.isBinary = true
            return f
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        let endsWithNewline = data.last == 0x0A
        if endsWithNewline { lines.removeLast() }
        f.additions = lines.count
        f.truncated = lines.count > maxLines
        var h = DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count)
        h.lines = lines.prefix(maxLines).enumerated().map {
            DiffLine(kind: .added, text: String(Substring($1)), newNumber: $0 + 1)
        }
        if !endsWithNewline, !f.truncated {
            h.lines.append(DiffLine(kind: .noNewline, text: "No newline at end of file"))
        }
        if !h.lines.isEmpty { f.hunks = [h] }
        return f
    }

    /// FNV-1a: в отличие от Hasher одинаков между запусками.
    static func fingerprint(_ f: DiffFile) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            h = (h ^ 0xFF) &* 0x100_0000_01b3
        }
        for s in [f.oldPath, f.newPath, f.oldMode, f.newMode] { mix(s ?? "") }
        // Хеши blob'ов нужны там, где содержимого в модели нет или оно неполное.
        if f.isBinary || f.truncated { mix(f.index ?? "") }
        for hunk in f.hunks {
            mix("\(hunk.oldStart),\(hunk.newStart)")
            for l in hunk.lines { mix("\(l.kind)"); mix(l.text) }
        }
        return String(h, radix: 16)
    }
}
