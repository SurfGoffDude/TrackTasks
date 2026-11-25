import Foundation

/// Отправка черновика агенту. Правка черновика её снимает: отметка есть только у версии, которая ушла.
public struct DiffDelivery: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case sending
        /// Агент мог его получить.
        case unclear
        /// Агент с ним не запускался.
        case failed
    }
    /// Id сообщения (`AgentReply.id`).
    public var reply: UUID
    public var state: State
    /// Доставка прошлой отправки этой же версии осталась неясной.
    public var maybeBefore: Bool?

    public init(reply: UUID, state: State, maybeBefore: Bool? = nil) {
        self.reply = reply
        self.state = state
        self.maybeBefore = maybeBefore
    }
}

/// Комментарий к строке или диапазону строк diff. Строки привязаны к номерам в файле:
/// `new` — новая версия (добавленные и контекстные), `old` — старая (удалённые).
public struct DiffComment: Codable, Identifiable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable { case old, new }

    public var id: UUID
    public var path: String
    public var side: Side
    public var start: Int
    public var end: Int
    /// Текст строк на момент комментария: по нему находят, что строки с тех пор изменились.
    public var snippet: [String]
    public var text: String
    public var created: Date
    public var delivery: DiffDelivery?

    // У черновиков прошлых версий этих полей нет.
    /// Соседние строки, ближайшая к фрагменту — первая. Пусто — в diff их не было.
    public var before: [String]?
    public var after: [String]?
    /// Хеш видимых строк стороны до конца диапазона: совпал — место точно прежнее.
    public var head: String?
    /// Уже при создании такое место было не одно: искать его после правок нельзя.
    public var repeated: Bool?
    /// Раздел diff, в котором оставлен комментарий.
    public var section: DiffSection.Kind?

    public init(id: UUID = UUID(), path: String, side: Side, start: Int, end: Int,
                snippet: [String], text: String, created: Date = Date()) {
        self.id = id; self.path = path; self.side = side
        self.start = min(start, end); self.end = max(start, end)
        self.snippet = snippet; self.text = text; self.created = created
    }

    /// Та же версия: уйдёт агенту тем же текстом. Дата не сравнивается — в файле она без долей секунды.
    public func sameVersion(_ o: DiffComment) -> Bool {
        id == o.id && path == o.path && side == o.side && start == o.start && end == o.end && snippet == o.snippet && text == o.text
    }

    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `12` или `12–14`.
    public var lines: String { start == end ? "\(start)" : "\(start)–\(end)" }

    /// Предел длины одной строки фрагмента: минифицированный код не должен раздувать сообщение.
    static let maxLine = 300
    static let maxSnippet = 60

    /// Строки файла выбранной стороны в диапазоне; пусто, если в diff таких строк нет.
    public static func snippet(of file: DiffFile, side: Side, start: Int, end: Int) -> [String] {
        let range = min(start, end)...max(start, end)
        return Array(DiffSide(file, side).lines.lazy.filter { range.contains($0.number) }.map(\.text).prefix(maxSnippet))
    }

    /// Создаёт комментарий, взяв фрагмент из файла. nil — в этом диапазоне нет строк diff.
    public static func make(file: DiffFile, side: Side, start: Int, end: Int, text: String,
                            section: DiffSection.Kind? = nil) -> DiffComment? {
        let s = snippet(of: file, side: side, start: start, end: end)
        guard !s.isEmpty else { return nil }
        var c = DiffComment(path: file.path, side: side, start: start, end: end, snippet: s, text: text)
        c.section = section
        let lines = DiffSide(file, side)
        if let first = lines.lines.firstIndex(where: { $0.number >= c.start }),
           let last = lines.lines.lastIndex(where: { $0.number <= c.end }) {
            c.before = lines.neighbours(first, -1)
            c.after = lines.neighbours(last, 1)
        }
        if lines.search(c) != .found(c.start) { c.repeated = true }
        c.head = lines.head(c.end)
        return c
    }

    /// Где фрагмент сейчас.
    public func locate(in file: DiffFile) -> DiffLocation { DiffSide(file, side).locate(self) }

    /// Комментарий на новом месте; nil — места нет или оно неоднозначно.
    public func moved(in file: DiffFile) -> DiffComment? {
        guard case .found(let n) = locate(in: file) else { return nil }
        return at(n)
    }

    func at(_ n: Int) -> DiffComment {
        var c = self
        c.start = n
        c.end = n + end - start
        return c
    }

    /// Строки изменились, исчезли из diff, или их место неоднозначно.
    public func isOutdated(in file: DiffFile?) -> Bool { file.flatMap(moved) == nil }
}

public enum DiffLocation: Equatable, Sendable {
    /// Номер первой строки.
    case found(Int)
    /// Такого текста нет.
    case missing
    /// Текст есть, но нельзя сказать, что это то самое место.
    case ambiguous
}

/// Видимые в diff строки одной стороны файла.
struct DiffSide {
    var lines: [(number: Int, text: String)] = []
    let truncated: Bool

    static let context = 3
    /// Столько букв и цифр отличают место от похожих, даже если соседние строки изменились.
    static let distinctive = 20

    init(_ file: DiffFile, _ side: DiffComment.Side) {
        truncated = file.truncated
        for l in file.hunks.lazy.flatMap(\.lines) {
            let n: Int? = switch l.kind {
            case .noNewline: nil
            case .removed: side == .old ? l.oldNumber : nil
            case .added: side == .new ? l.newNumber : nil
            case .context: side == .old ? l.oldNumber : l.newNumber
            }
            guard let n else { continue }
            var t = l.text
            if t.utf8.last == 0x0D { t = String(Substring(t.utf8.dropLast())) }
            if t.utf8.count > DiffComment.maxLine, t.count > DiffComment.maxLine { t = t.prefix(DiffComment.maxLine) + "…" }
            lines.append((n, t))
        }
    }

    /// Строки подряд рядом с `i`, ближайшая — первая.
    func neighbours(_ i: Int, _ step: Int) -> [String] {
        var out: [String] = []
        var k = i + step
        while out.count < Self.context, lines.indices.contains(k), lines[k].number == lines[k - step].number + step {
            out.append(lines[k].text)
            k += step
        }
        return out
    }

    func head(_ end: Int) -> String {
        DiffComments.hash(lines.lazy.filter { $0.number <= end }.map { "\($0.number):\($0.text)" }.joined(separator: "\n"))
    }

    func locate(_ c: DiffComment) -> DiffLocation {
        if let h = c.head, h == head(c.end) { return .found(c.start) }
        guard c.repeated == true else { return search(c) }
        return matches(c).isEmpty ? .missing : .ambiguous
    }

    /// Индексы первых строк всех вхождений фрагмента.
    private func matches(_ c: DiffComment) -> [Int] {
        let k = c.snippet.count
        guard k > 0, lines.count >= k else { return [] }
        // Обрезанный фрагмент — начало диапазона, и строки в нём должны идти подряд.
        let span = k == DiffComment.maxSnippet ? k - 1 : c.end - c.start
        return (0...(lines.count - k)).filter { i in
            lines[i].text == c.snippet[0] && lines[i + k - 1].number - lines[i].number == span
                && (1..<k).allSatisfy { lines[i + $0].text == c.snippet[$0] }
        }
    }

    private struct Candidate {
        let number: Int
        /// nil — сравнить не с чем.
        let before, after: Bool?
        /// Буквы и цифры совпавших строк.
        let evidence: Int
        var fits: Bool { before != false && after != false }
        var confirmed: Bool { before == true || after == true }
    }

    /// Поиск по тексту и соседним строкам.
    func search(_ c: DiffComment) -> DiffLocation {
        let own = Self.weight(c.snippet)
        let all = matches(c).map { i -> Candidate in
            let last = i + c.snippet.count - 1
            let up = neighbours(i, -1), down = neighbours(last, 1)
            let b = c.before ?? [], a = c.after ?? []
            return Candidate(number: lines[i].number,
                             before: lines[i].number == 1 && !b.isEmpty ? false : Self.same(b, up),
                             after: Self.same(a, down),
                             evidence: own + Self.weight(Self.common(b, up)) + Self.weight(Self.common(a, down)))
        }
        guard let first = all.first else { return .missing }
        if all.count == 1 {
            if first.number == c.start { return .found(first.number) }
            if first.confirmed, first.fits { return .found(first.number) }
            // В усечённом файле такой же текст может быть дальше.
            if truncated { return .ambiguous }
            let ok = first.fits ? own > 0 : first.evidence >= Self.distinctive
            return ok ? .found(first.number) : .ambiguous
        }
        let fits = all.filter(\.fits)
        if fits.count == 1, fits[0].confirmed { return .found(fits[0].number) }
        guard fits.isEmpty, !truncated else { return .ambiguous }
        // Рядом с самим местом вставили строку: вторая сторона осталась прежней.
        let half = all.filter(\.confirmed)
        return half.count == 1 && half[0].evidence >= Self.distinctive ? .found(half[0].number) : .ambiguous
    }

    private static func common(_ a: [String], _ b: [String]) -> [String] {
        zip(a, b).prefix { $0 == $1 }.map(\.0)
    }

    private static func same(_ a: [String], _ b: [String]) -> Bool? {
        let n = min(a.count, b.count)
        return n == 0 ? nil : common(a, b).count == n
    }

    private static func weight(_ s: [String]) -> Int {
        s.reduce(0) { $0 + $1.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) } }
    }
}

public enum DiffComments {
    /// Место комментария среди файлов diff.
    public struct Place: Equatable, Sendable {
        /// `DiffSection.Entry.id` файлов, где он стоит.
        public var entries: [String]
        /// С номерами строк на новом месте. Сам черновик не меняется: иначе это была бы другая версия.
        public var comment: DiffComment
    }

    /// Места комментариев; у устаревших их нет.
    public static func places(_ comments: [DiffComment], in sections: [DiffSection]) -> [UUID: Place] {
        var out: [UUID: Place] = [:]
        for c in comments {
            // Сначала свой раздел; если текста там нет — другой: правки могли закоммитить.
            let groups = c.section.map { own in
                [sections.filter { $0.kind == own }, sections.filter { $0.kind != own }]
            } ?? [sections]
            for g in groups {
                let found = g.flatMap(\.entries).filter { $0.file.path == c.path }
                    .map { (id: $0.id, at: c.locate(in: $0.file)) }.filter { $0.at != .missing }
                guard let first = found.first else { continue }
                if case .found(let n) = first.at, found.allSatisfy({ $0.at == first.at }) {
                    out[c.id] = Place(entries: found.map(\.id), comment: c.at(n))
                }
                break
            }
        }
        return out
    }

    /// Сохранить новый или правленый комментарий. `original` — версия, с которой открыли редактор.
    public static func upsert(_ c: DiffComment, original: DiffComment, in list: inout [DiffComment]) {
        guard let i = list.firstIndex(where: { $0.id == c.id }) else {
            // Доставлен и удалён, пока был открыт редактор, а текст не меняли.
            if original.delivery != nil, c.sameVersion(original) { return }
            var c = c
            c.delivery = nil
            list.append(c)
            return
        }
        var c = c
        c.delivery = c.sameVersion(list[i]) ? list[i].delivery : nil
        list[i] = c
    }

    /// Отметить отправленные версии.
    public static func markSent(_ sent: [DiffComment], reply: UUID, in list: inout [DiffComment]) {
        for i in list.indices where sent.contains(where: { $0.sameVersion(list[i]) }) {
            let old = list[i].delivery
            list[i].delivery = DiffDelivery(reply: reply, state: .sending,
                                            maybeBefore: old?.state == .unclear || old?.maybeBefore == true ? true : nil)
        }
    }

    /// Чем кончилась отправка: nil — дошло, удаляются только версии из этого сообщения.
    public static func settle(_ reply: UUID, _ state: DiffDelivery.State?, in list: inout [DiffComment]) {
        guard let state else { return list.removeAll { $0.delivery?.reply == reply } }
        for i in list.indices where list[i].delivery?.reply == reply {
            let maybe = list[i].delivery?.maybeBefore == true
            list[i].delivery?.state = state == .failed && maybe ? .unclear : state
        }
    }

    /// Диапазон строк по выбранным строкам таблицы. Если среди них есть новые строки — берётся новая
    /// сторона (удалённые строки пропускаются), иначе старая.
    public static func anchor(_ rows: [DiffRow]) -> (side: DiffComment.Side, start: Int, end: Int)? {
        var new: [Int] = [], old: [Int] = []
        func add(_ l: DiffLine) {
            if l.kind == .noNewline { return }
            if l.kind == .removed { if let n = l.oldNumber { old.append(n) } } else if let n = l.newNumber { new.append(n) }
        }
        for r in rows {
            switch r {
            case .hunk: break
            case .line(let l): add(l)
            case .pair(let a, let b):
                if let b, b.kind != .removed { add(b) } else if let a { add(a) }
            }
        }
        if let lo = new.min(), let hi = new.max() { return (.new, lo, hi) }
        if let lo = old.min(), let hi = old.max() { return (.old, lo, hi) }
        return nil
    }

    /// Ключи строк таблицы с комментариями: `new:12` / `old:7` → true, если комментарий устарел.
    public static func marks(_ comments: [DiffComment], outdated: Set<UUID>) -> [String: Bool] {
        var m: [String: Bool] = [:]
        for c in comments {
            for n in c.start...c.end {
                let k = key(c.side, n)
                m[k] = (m[k] ?? false) || outdated.contains(c.id)
            }
        }
        return m
    }

    public static func key(_ side: DiffComment.Side, _ n: Int) -> String { "\(side.rawValue):\(n)" }

    /// Сообщение агенту: для каждого комментария файл, строки, фрагмент и текст.
    public static func format(_ comments: [DiffComment], outdated: Set<UUID> = []) -> String {
        let list = comments.filter { !$0.isBlank }
        guard !list.isEmpty else { return "" }
        var out = "Комментарии к изменениям по задаче (\(list.count)). У каждого указаны файл, строки и фрагмент кода. "
            + "Учти замечания и внеси правки; если с замечанием не согласен — объясни почему.\n"
        for (i, c) in list.enumerated() {
            let side = c.side == .new ? "" : " (старая версия, удалённые строки)"
            out += "\n\(i + 1). \(c.path):\(c.lines)\(side)"
            if outdated.contains(c.id) { out += " — строки с тех пор изменились или их место неясно, фрагмент ниже устарел" }
            out += "\n"
            let body = c.snippet.joined(separator: "\n")
            var fence = "```"
            while body.contains(fence) { fence += "`" }
            out += "\(fence)\n\(body)\n\(fence)\n"
            out += "Комментарий: \(c.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return out
    }

    /// Имя файла черновиков для источника diff: FNV-1a от ключа (стабилен между запусками).
    public static func fileName(forKey key: String) -> String { hash(key) + ".json" }

    static func hash(_ key: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}
