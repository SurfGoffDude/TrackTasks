import Foundation

/// Файл из `git status`.
public struct GitFile: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case staged, unstaged, partial, untracked, conflict }
    /// Путь байтами, как его хранит git: имя может быть не в UTF-8, а String равняет разные записи «й».
    public var raw: Data
    /// Вторая сторона переименования.
    public var rawOld: Data?
    /// Что в индексе и что в папке («.» — без изменений).
    public var index: Character
    public var worktree: Character
    /// Объект в индексе.
    public var indexHash = ""
    public var kind: Kind

    public var id: Data { raw }
    public var path: String { String(decoding: raw, as: UTF8.self) }
    public var oldPath: String? { rawOld.map { String(decoding: $0, as: UTF8.self) } }
    /// Есть что-то в индексе.
    public var inIndex: Bool { index != "." && kind != .conflict && kind != .untracked }
    public var isNestedRepo: Bool { kind == .untracked && raw.last == UInt8(ascii: "/") }
    var paths: [Data] { [raw] + (rawOld.map { [$0] } ?? []) }
}

/// Выбор файлов для коммита. Индекс меняется только в `commit`.
public enum GitStaging {
    public static func status(_ dir: URL, git: GitRun.Runner) -> Result<[GitFile], GitRun.Failure> {
        let o = GitRun.read(["status", "--porcelain=v2", "-z", "-uall", "--find-renames"], dir, git)
        return o.ok ? .success(parse(o.out)) : .failure(.init(GitRun.message(o)))
    }

    static func parse(_ out: Data) -> [GitFile] {
        var files: [GitFile] = []
        var byPath: [Data: Int] = [:]
        var parts = out.split(separator: 0).map { Data($0) }[...]
        while let e = parts.popFirst() {
            guard let type = e.first.map({ Character(UnicodeScalar($0)) }) else { continue }
            func fields(_ n: Int) -> (head: [String], path: Data)? {
                let f = e.split(separator: 0x20, maxSplits: n, omittingEmptySubsequences: false)
                guard f.count == n + 1 else { return nil }
                return (f.dropLast().map { String(decoding: $0, as: UTF8.self) }, Data(f[n]))
            }
            switch type {
            case "1", "2":
                let old = type == "2" ? parts.popFirst() : nil
                guard let (h, path) = fields(type == "1" ? 8 : 9), h[1].count == 2 else { continue }
                let x = h[1].first!, y = h[1].last!
                // Правки внутри подмодуля коммитом этого репозитория не станут.
                if x == ".", h[2].hasPrefix("S"), !h[2].hasPrefix("SC"), y == "M" { continue }
                let renamed = x == "R" || y == "R"
                byPath[path] = files.count
                files.append(GitFile(raw: path, rawOld: renamed ? old : nil, index: x, worktree: y, indexHash: h[7],
                                     kind: x == "." ? .unstaged : y == "." ? .staged : .partial))
            case "u":
                guard let (_, path) = fields(10) else { continue }
                files.append(GitFile(raw: path, index: "U", worktree: "U", kind: .conflict))
            case "?":
                let path = Data(e.dropFirst(2))
                // Убран из индекса, но лежит в папке: одна строка, а не две с одним путём.
                if let i = byPath[path] {
                    files[i].worktree = "?"
                    files[i].kind = .partial
                } else {
                    files.append(GitFile(raw: path, index: "?", worktree: "?", kind: .untracked))
                }
            default: break
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Индекс пуст — всё, кроме похожего на секреты и вложенных репозиториев; иначе то, что уже в индексе.
    public static func defaultSelection(_ files: [GitFile], risky: Set<String>) -> Set<Data> {
        let staged = files.filter(\.inIndex)
        if !staged.isEmpty { return Set(staged.map(\.id)) }
        return Set(files.filter { $0.kind != .conflict && !$0.isNestedRepo && !risky.contains($0.path) }.map(\.id))
    }

    /// Снятые с отметки файлы, чья версия в индексе отличается от папки: она пропадёт.
    public static func lost(_ files: [GitFile], selected: Set<Data>) -> [GitFile] {
        files.filter { $0.kind == .partial && !selected.contains($0.id) }
    }

    /// `shown` — список, который видел пользователь. Отмеченное частично добавленное не трогается: идёт версия из индекса.
    /// `mayLose` — пользователь согласился потерять версии из `lost`.
    public static func commit(_ dir: URL, message: String, shown: [GitFile], selected: Set<Data>, mayLose: Bool = false,
                              git: GitRun.Runner) -> Result<String, GitRun.Failure> {
        func fail(_ m: String) -> Result<String, GitRun.Failure> { .failure(.init(m)) }
        if let op = GitBranches.operation(dir, git: git) { return fail("Не закончена операция git: \(op) — закончи её в терминале") }
        let now: [GitFile]
        switch status(dir, git: git) {
        case .failure(let e): return .failure(e)
        case .success(let f): now = f
        }
        if let c = now.first(where: { $0.kind == .conflict }) { return fail("Неразрешённый конфликт: \(c.path)") }
        // Неотмеченное и не добавленное в индекс может меняться сколько угодно (tasks/ пишут агенты).
        func matters(_ f: GitFile) -> Bool { f.inIndex || selected.contains(f.id) }
        guard Set(now.filter(matters)) == Set(shown.filter(matters)) else { return fail("Список изменений уже другой — проверь отметки ещё раз") }
        let chosen = now.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return fail("Ничего не выбрано") }
        guard mayLose || lost(now, selected: selected).isEmpty else { return fail("Нужно подтверждение: пропадут версии файлов из индекса") }

        func paths(_ args: [String], _ files: [GitFile]) -> DiffReject.Output? {
            guard !files.isEmpty else { return nil }
            var input = Data()
            for p in files.flatMap(\.paths) { input += p + [0] }
            let o = git(args + ["--pathspec-from-file=-", "--pathspec-file-nul"], dir, ["GIT_LITERAL_PATHSPECS": "1"], input)
            return o.ok ? nil : o
        }
        let unstage = now.filter { $0.inIndex && !selected.contains($0.id) }
        let head = GitRun.hasHead(dir, git)
        if let o = paths(head ? ["restore", "--staged"] : ["rm", "-q", "-f", "--cached"], unstage) { return fail(GitRun.message(o)) }
        let touched = "\nИндекс уже изменён по отметкам, сами файлы не тронуты."
        if let o = paths(["add", "-A"], chosen.filter { !$0.inIndex }) { return fail(GitRun.message(o) + (unstage.isEmpty ? "" : touched)) }
        if head, GitRun.read(["diff", "--cached", "--quiet"], dir, git).ok { return fail("В выбранных файлах нечего коммитить") }
        let o = git(["commit", "-q", "-m", message], dir, [:], nil)
        guard o.ok else { return fail(GitRun.message(o) + touched) }
        return .success(GitRun.line(["log", "-1", "--no-show-signature", "--format=%h %s"], dir, git) ?? "Готово")
    }

    /// Diff отмеченного для черновика сообщения: у добавленного — из индекса, у остального — из папки.
    public static func diff(_ dir: URL, files: [GitFile], git: GitRun.Runner) -> String {
        func run(_ extra: [String], _ f: [GitFile]) -> String {
            guard !f.isEmpty else { return "" }
            // Черновику хватит начала; слишком длинная командная строка не запустится.
            let p = f.prefix(300).map(\.path)
            return git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--stat", "-p"] + extra + ["--"] + p, dir,
                       ["GIT_LITERAL_PATHSPECS": "1", "GIT_OPTIONAL_LOCKS": "0"], nil).text
        }
        return run(["--cached"], files.filter(\.inIndex)) + run([], files.filter { $0.kind == .unstaged })
    }
}
