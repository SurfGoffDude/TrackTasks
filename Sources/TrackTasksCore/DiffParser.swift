import Foundation

/// Разбор вывода `git diff` в модель. Чистая логика, без процессов.

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed, noNewline }
    public var kind: Kind
    /// Текст без ведущего маркера (` `, `+`, `-`).
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind; self.text = text; self.oldNumber = oldNumber; self.newNumber = newNumber
    }
}

public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Текст после второго `@@` (обычно имя функции).
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                section: String = "", lines: [DiffLine] = []) {
        self.oldStart = oldStart; self.oldCount = oldCount
        self.newStart = newStart; self.newCount = newCount
        self.section = section; self.lines = lines
    }
}

public struct DiffFile: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case modified, added, deleted, renamed, copied }

    public var oldPath: String?
    public var newPath: String?
    public var status: Status = .modified
    public var isBinary = false
    public var oldMode: String?
    public var newMode: String?
    /// Хеши содержимого из строки `index a..b`.
    public var index: String?
    /// Процент сходства для rename/copy.
    public var similarity: Int?
    public var hunks: [DiffHunk] = []
    /// Строки, добавленные / удалённые во всём файле (считаются и при усечении).
    public var additions = 0
    public var deletions = 0
    /// Часть кусков отброшена из-за лимита.
    public var truncated = false

    public init(oldPath: String? = nil, newPath: String? = nil) {
        self.oldPath = oldPath; self.newPath = newPath
    }

    /// Путь для показа: новый, а для удалённого — старый.
    public var path: String { newPath ?? oldPath ?? "" }
    public var modeChanged: Bool { oldMode != nil && newMode != nil && oldMode != newMode }
}

public struct DiffResult: Equatable, Sendable {
    public var files: [DiffFile] = []
    /// Не все файлы или строки попали в результат.
    public var truncated = false
    /// Сколько файлов отброшено целиком из-за лимита.
    public var skippedFiles = 0
}

public enum DiffParser {
    public struct Limits: Sendable {
        /// Макс. строк в кусках одного файла.
        public var maxLinesPerFile: Int
        /// Макс. строк в кусках всех файлов.
        public var maxTotalLines: Int
        /// Макс. файлов.
        public var maxFiles: Int
        public init(maxLinesPerFile: Int = 5_000, maxTotalLines: Int = 50_000, maxFiles: Int = 500) {
            self.maxLinesPerFile = maxLinesPerFile
            self.maxTotalLines = maxTotalLines
            self.maxFiles = maxFiles
        }
        public static let `default` = Limits()
        public static let unlimited = Limits(maxLinesPerFile: .max, maxTotalLines: .max, maxFiles: .max)
    }

    public static func parse(_ text: String, limits: Limits = .default) -> DiffResult {
        // Резать по байту \n: "\r\n" в Swift — один Character, split по Character его бы не нашёл.
        let lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { Substring($0) }
        var result = DiffResult()
        var i = 0
        var totalLines = 0
        let n = lines.count

        while i < n {
            let line = lines[i]
            guard line.hasPrefix("diff --git ") else { i += 1; continue }

            let (a, b) = headerPaths(String(line.dropFirst("diff --git ".count)))
            var file = DiffFile(oldPath: a, newPath: b)
            i += 1

            // Расширенный заголовок до первого @@ или следующего diff.
            var renameFrom: String?, renameTo: String?
            var headerDone = false
            while i < n, !headerDone {
                let l = lines[i]
                if l.hasPrefix("@@") || l.hasPrefix("diff --git ") { break }
                if l.hasPrefix("old mode ") { file.oldMode = String(l.dropFirst(9)) }
                else if l.hasPrefix("index ") { file.index = String(l.dropFirst(6)) }
                else if l.hasPrefix("new mode ") { file.newMode = String(l.dropFirst(9)) }
                else if l.hasPrefix("deleted file mode ") {
                    file.status = .deleted; file.oldMode = String(l.dropFirst(18))
                } else if l.hasPrefix("new file mode ") {
                    file.status = .added; file.newMode = String(l.dropFirst(14))
                } else if l.hasPrefix("similarity index ") {
                    file.similarity = Int(l.dropFirst(17).trimmingCharacters(in: CharacterSet(charactersIn: "%")))
                } else if l.hasPrefix("rename from ") {
                    file.status = .renamed; renameFrom = unquote(String(l.dropFirst(12)))
                } else if l.hasPrefix("rename to ") {
                    file.status = .renamed; renameTo = unquote(String(l.dropFirst(10)))
                } else if l.hasPrefix("copy from ") {
                    file.status = .copied; renameFrom = unquote(String(l.dropFirst(10)))
                } else if l.hasPrefix("copy to ") {
                    file.status = .copied; renameTo = unquote(String(l.dropFirst(8)))
                } else if l.hasPrefix("Binary files ") || l.hasPrefix("GIT binary patch") {
                    file.isBinary = true
                } else if l.hasPrefix("--- ") {
                    if let p = markerPath(l.dropFirst(4), prefix: "a/") { file.oldPath = p }
                    else if l.dropFirst(4).hasPrefix("/dev/null") { file.oldPath = nil }
                } else if l.hasPrefix("+++ ") {
                    if let p = markerPath(l.dropFirst(4), prefix: "b/") { file.newPath = p }
                    else if l.dropFirst(4).hasPrefix("/dev/null") { file.newPath = nil }
                }
                i += 1
            }
            if let f = renameFrom { file.oldPath = f }
            if let t = renameTo { file.newPath = t }
            if file.status == .added { file.oldPath = nil }
            if file.status == .deleted { file.newPath = nil }

            // Куски.
            var fileLines = 0
            while i < n, lines[i].hasPrefix("@@") {
                guard var hunk = parseHunkHeader(lines[i]) else { i += 1; continue }
                i += 1
                var oldLeft = hunk.oldCount, newLeft = hunk.newCount
                var oldNo = hunk.oldStart, newNo = hunk.newStart
                let keep = fileLines < limits.maxLinesPerFile && totalLines < limits.maxTotalLines
                if keep { hunk.lines.reserveCapacity(oldLeft + newLeft) }

                while i < n, oldLeft > 0 || newLeft > 0 {
                    let l = lines[i]
                    let kind: DiffLine.Kind
                    if l.hasPrefix("+") { kind = .added }
                    else if l.hasPrefix("-") { kind = .removed }
                    else if l.hasPrefix("\\") {
                        if keep, !hunk.lines.isEmpty, hunk.lines.last?.kind != .noNewline {
                            hunk.lines.append(DiffLine(kind: .noNewline, text: String(l.dropFirst(2))))
                        }
                        i += 1; continue
                    }
                    else if l.isEmpty && i == n - 1 { break } // хвост текста
                    else { kind = .context } // " " либо пустая строка (редакторы срезают пробел)

                    switch kind {
                    case .added: newLeft -= 1; file.additions += 1
                    case .removed: oldLeft -= 1; file.deletions += 1
                    default: oldLeft -= 1; newLeft -= 1
                    }
                    if keep, fileLines < limits.maxLinesPerFile, totalLines < limits.maxTotalLines {
                        let body = l.isEmpty ? "" : String(l.dropFirst())
                        switch kind {
                        case .added:
                            hunk.lines.append(DiffLine(kind: .added, text: body, newNumber: newNo))
                        case .removed:
                            hunk.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldNo))
                        default:
                            hunk.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldNo, newNumber: newNo))
                        }
                        fileLines += 1; totalLines += 1
                    } else {
                        file.truncated = true
                    }
                    if kind != .added { oldNo += 1 }
                    if kind != .removed { newNo += 1 }
                    i += 1
                }
                // «\ No newline at end of file» относится к предыдущей строке.
                while i < n, lines[i].hasPrefix("\\") {
                    if keep, hunk.lines.last?.kind != .noNewline, hunk.lines.last != nil {
                        hunk.lines.append(DiffLine(kind: .noNewline, text: String(lines[i].dropFirst(2))))
                    }
                    i += 1
                }
                if keep, !hunk.lines.isEmpty || hunk.oldCount + hunk.newCount == 0 {
                    file.hunks.append(hunk)
                } else if !keep {
                    file.truncated = true
                }
            }
            // Мусор до следующего diff (напр. текст бинарного патча) пропустит внешний цикл.

            if result.files.count >= limits.maxFiles {
                result.skippedFiles += 1
                result.truncated = true
            } else {
                if file.truncated { result.truncated = true }
                result.files.append(file)
            }
        }
        return result
    }

    // MARK: - Пути

    /// Пути из `diff --git <a> <b>`. Пробелы без кавычек неоднозначны — ищем симметричную пару.
    static func headerPaths(_ rest: String) -> (String?, String?) {
        if rest.hasPrefix("\"") {
            guard let (first, after) = readQuoted(rest) else { return (nil, nil) }
            let tail = after.drop(while: { $0 == " " })
            let second: String
            if tail.hasPrefix("\"") { second = readQuoted(String(tail))?.0 ?? String(tail) }
            else { second = String(tail) }
            return (stripPrefix(first, "a/"), stripPrefix(second, "b/"))
        }
        // Либо `a/x "b/y"`.
        if let q = rest.range(of: " \"b/") {
            let first = String(rest[rest.startIndex..<q.lowerBound])
            let second = readQuoted(String(rest[rest.index(after: q.lowerBound)...]))?.0 ?? ""
            return (stripPrefix(first, "a/"), stripPrefix(second, "b/"))
        }
        // `a/P b/P`: ищем " b/", после которого путь совпадает с путём до него.
        // Иначе (переименование) берём первое вхождение; уточнят `rename from/to` и `---`/`+++`.
        var firstSplit: (String, String)?
        var from = rest.startIndex
        while let r = rest.range(of: " b/", range: from..<rest.endIndex) {
            let left = String(rest[rest.startIndex..<r.lowerBound])
            let right = String(rest[r.upperBound...])
            if left.hasPrefix("a/"), String(left.dropFirst(2)) == right { return (right, right) }
            if firstSplit == nil { firstSplit = (stripPrefix(left, "a/"), right) }
            from = r.upperBound
        }
        if let f = firstSplit { return f }
        return (nil, nil)
    }

    private static func stripPrefix(_ s: String, _ p: String) -> String {
        s.hasPrefix(p) ? String(s.dropFirst(p.count)) : s
    }

    /// Путь из строки `--- ` / `+++ `: убирает кавычки, `a/`/`b/` и хвостовой таб.
    private static func markerPath(_ s: Substring, prefix: String) -> String? {
        if s.hasPrefix("/dev/null") { return nil }
        var str = String(s)
        if str.hasSuffix("\t") { str.removeLast() }
        str = unquote(str)
        guard str.hasPrefix(prefix) else { return nil }
        return String(str.dropFirst(prefix.count))
    }

    /// Снимает C-кавычки git (`"\320\277 \"x\""`), иначе возвращает как есть.
    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), let (v, _) = readQuoted(s) else { return s }
        return v
    }

    /// Читает строку в кавычках с эскейпами git; возвращает значение и остаток.
    static func readQuoted(_ s: String) -> (String, Substring)? {
        let u = Array(s.utf8)
        guard u.first == 0x22 else { return nil }
        var out: [UInt8] = []
        var i = 1
        while i < u.count {
            let c = u[i]
            if c == 0x22 {
                let rest = String(decoding: u[(i + 1)...], as: UTF8.self)
                return (String(decoding: out, as: UTF8.self), Substring(rest))
            }
            if c == 0x5C, i + 1 < u.count {
                i += 1
                let e = u[i]
                switch e {
                case 0x30...0x37: // до трёх восьмеричных цифр
                    var v = Int(e - 0x30)
                    var k = 1
                    while k < 3, i + 1 < u.count, (0x30...0x37).contains(u[i + 1]) {
                        i += 1; v = v * 8 + Int(u[i] - 0x30); k += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: v))
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x61: out.append(0x07)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x76: out.append(0x0B)
                default: out.append(e) // \\ и \"
                }
            } else {
                out.append(c)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Куски

    /// `@@ -a[,b] +c[,d] @@ section`
    static func parseHunkHeader(_ line: Substring) -> DiffHunk? {
        let u = line.utf8
        var idx = u.startIndex
        func skip(_ s: String) -> Bool {
            var j = idx
            for b in s.utf8 {
                guard j < u.endIndex, u[j] == b else { return false }
                j = u.index(after: j)
            }
            idx = j; return true
        }
        func int() -> Int? {
            var v = 0, any = false
            while idx < u.endIndex, (0x30...0x39).contains(u[idx]) {
                v = v * 10 + Int(u[idx] - 0x30); any = true
                idx = u.index(after: idx)
            }
            return any ? v : nil
        }
        guard skip("@@ -"), let os = int() else { return nil }
        var oc = 1
        if skip(",") { guard let v = int() else { return nil }; oc = v }
        guard skip(" +"), let ns = int() else { return nil }
        var nc = 1
        if skip(",") { guard let v = int() else { return nil }; nc = v }
        guard skip(" @@") else { return nil }
        let section = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return DiffHunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc, section: section)
    }
}
