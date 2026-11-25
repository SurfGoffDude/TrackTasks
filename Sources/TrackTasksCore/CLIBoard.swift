import Foundation

/// State and drawing of the interactive board: no terminal, no files — so it can be tested.
struct BoardModel {
    struct Card: Equatable {
        var id: String
        var project: String
        var fileName: String
        var title: String
        var priority: Priority
        var status: TaskStatus
        var rev: String
    }

    enum Key: Equatable {
        case up, down, left, right, quit, refresh
        case move(Int)          // -1 / +1: to the neighbouring column
        case set(TaskStatus)
    }

    static let statuses = TaskStatus.allCases
    var columns: [[Card]] = [[], [], []]
    var col = 0
    var row = 0
    var message = ""
    var showProject = false

    var selected: Card? {
        guard columns.indices.contains(col), columns[col].indices.contains(row) else { return nil }
        return columns[col][row]
    }

    /// Replaces the cards, keeping the selection on the same task (or the same place if it is gone).
    mutating func load(_ cards: [Card], keep id: String? = nil) {
        let keepID = id ?? selected?.id
        columns = Self.statuses.map { s in
            var c = cards.filter { $0.status == s }
            if s == .done { c.sort { $0.fileName > $1.fileName } }
            return c
        }
        if let keepID, let (c, r) = locate(keepID) { col = c; row = r } else { clamp() }
    }

    func locate(_ id: String) -> (Int, Int)? {
        for (c, cards) in columns.enumerated() { if let r = cards.firstIndex(where: { $0.id == id }) { return (c, r) } }
        return nil
    }

    private mutating func clamp() {
        col = min(max(col, 0), columns.count - 1)
        row = min(max(row, 0), max(columns[col].count - 1, 0))
    }

    /// Moves the cursor; `.left`/`.right` skip nothing: an empty column is still a column.
    mutating func navigate(_ key: Key) {
        switch key {
        case .up: row = max(row - 1, 0)
        case .down: row = min(row + 1, max(columns[col].count - 1, 0))
        case .left: col = max(col - 1, 0); clamp()
        case .right: col = min(col + 1, columns.count - 1); clamp()
        default: break
        }
    }

    /// Target status of a key for the selected card; nil — nothing to do.
    func target(_ key: Key) -> TaskStatus? {
        guard let card = selected, let i = Self.statuses.firstIndex(of: card.status) else { return nil }
        switch key {
        case .move(let d):
            let j = i + d
            return Self.statuses.indices.contains(j) ? Self.statuses[j] : nil
        case .set(let s): return s == card.status ? nil : s
        default: return nil
        }
    }

    // MARK: Input

    /// Keys of a chunk read from the terminal. Unknown bytes are skipped.
    static func keys(_ bytes: [UInt8]) -> [Key] {
        var out: [Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            switch b {
            case 0x1B:
                if i < bytes.count, bytes[i] == 0x5B || bytes[i] == 0x4F {
                    i += 1
                    // CSI: parameters, then a final letter.
                    while i < bytes.count, bytes[i] < 0x40 { i += 1 }
                    guard i < bytes.count else { break }
                    switch bytes[i] {
                    case 0x41: out.append(.up)
                    case 0x42: out.append(.down)
                    case 0x43: out.append(.right)
                    case 0x44: out.append(.left)
                    default: break
                    }
                    i += 1
                } else if i >= bytes.count {
                    out.append(.quit)
                }
            case 0x03, 0x04, UInt8(ascii: "q"), UInt8(ascii: "Q"): out.append(.quit)
            case UInt8(ascii: "k"): out.append(.up)
            case UInt8(ascii: "j"): out.append(.down)
            case UInt8(ascii: "h"): out.append(.left)
            case UInt8(ascii: "l"): out.append(.right)
            case UInt8(ascii: "H"), UInt8(ascii: "<"), UInt8(ascii: ","): out.append(.move(-1))
            case UInt8(ascii: "L"), UInt8(ascii: ">"), UInt8(ascii: "."): out.append(.move(1))
            case UInt8(ascii: "1"): out.append(.set(.todo))
            case UInt8(ascii: "2"): out.append(.set(.doing))
            case UInt8(ascii: "3"): out.append(.set(.done))
            case UInt8(ascii: "r"), UInt8(ascii: "R"): out.append(.refresh)
            default: break
            }
        }
        return out
    }

    // MARK: Drawing

    /// Text without control characters, cut or padded to `width` columns.
    static func fit(_ s: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        let clean = s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) ? " " : String($0) }.joined()
        var chars = Array(clean)
        if chars.count > width { chars = Array(chars.prefix(max(width - 1, 0))) + (width > 0 ? ["…"] : []) }
        return String(chars) + String(repeating: " ", count: max(width - chars.count, 0))
    }

    /// A whole screen as `height` lines; the first and last are the header and the hint.
    func frame(width: Int, height: Int, ansi: Bool = true) -> [String] {
        let w = max(width, 30)
        let h = max(height, 5)
        let cw = (w - 4) / 3
        let rows = h - 3
        func style(_ s: String, _ code: String) -> String { ansi ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        var lines: [String] = []
        lines.append(Self.fit("Доска", w))
        var head: [String] = []
        for (c, s) in Self.statuses.enumerated() {
            let t = Self.fit("\(s.title) (\(columns[c].count))", cw)
            head.append(c == col ? style(t, "1;4") : style(t, "2"))
        }
        lines.append(head.joined(separator: "  "))
        // Each column scrolls so that the cursor stays visible.
        let tops = columns.indices.map { c -> Int in
            guard c == col else { return 0 }
            return max(0, min(row - rows + 1, max(columns[c].count - rows, 0)))
        }
        for r in 0..<rows {
            var cells: [String] = []
            for c in columns.indices {
                let i = tops[c] + r
                guard columns[c].indices.contains(i) else { cells.append(String(repeating: " ", count: cw)); continue }
                let card = columns[c][i]
                let mark = card.priority == .high ? "!" : card.priority == .low ? "-" : " "
                let proj = showProject ? "[\(card.project)] " : ""
                let text = Self.fit("\(mark)\(proj)\(card.title)", cw)
                cells.append(c == col && i == row ? style(text, "7") : text)
            }
            lines.append(cells.joined(separator: "  "))
        }
        let hint = message.isEmpty ? "←↑↓→ hjkl · H/L или 1 2 3 — статус · r обновить · q выход" : message
        lines.append(Self.fit(hint, w))
        return lines
    }
}

extension CLI {
    /// nil — no raw mode (not a real terminal): the caller prints the text board.
    func interactiveBoard(_ args: CLIArgs) throws -> Int32? {
        _ = try execute("board", args)    // wrong arguments or a missing project end the command as usual
        guard let term = BoardTerminal() else { return nil }
        let all = args.has("all")
        let paths = all ? [root.path] + extras : [try projectURL(args).path]
        let flags = term.flags
        let watcher = FileWatcher(paths: paths) { events in
            if events.contains(where: { Self.matters($0) }) { flags.set(.changed) }
        }
        var model = BoardModel()
        model.showProject = all

        func cards() throws -> [BoardModel.Card] {
            let ctxs = try contexts(args)
            return try matching(args, ctxs, defaultStatuses: TaskStatus.allCases).map { ctx, f in
                BoardModel.Card(id: ctx.url.path + "/" + f.item.fileName, project: ctx.name, fileName: f.item.fileName,
                                title: f.item.title, priority: f.item.priority, status: f.item.status, rev: f.rev)
            }
        }
        func reload(keep: String? = nil) {
            do { model.load(try cards(), keep: keep) } catch { model.message = CLIError(error).message }
        }
        func draw() {
            let (w, h) = term.size()
            let lines = model.frame(width: w, height: h)
            out("\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n") + "\u{1B}[J")
        }
        func apply(_ key: BoardModel.Key) -> Bool {
            model.message = ""
            switch key {
            case .quit: return false
            case .refresh: reload()
            case .up, .down, .left, .right: model.navigate(key)
            case .move, .set:
                guard let card = model.selected, let status = model.target(key) else { break }
                let a = CLIArgs(positional: [card.fileName],
                                values: ["project": [String(card.id.dropLast(card.fileName.count + 1))],
                                         "status": [status.rawValue], "if-rev": [card.rev]])
                do {
                    _ = try execute("edit", a)
                    reload(keep: card.id)
                } catch {
                    model.message = CLIError(error).message
                    reload()
                }
            }
            return true
        }

        reload()
        term.enter()
        draw()
        var running = true
        while running {
            let input = term.read(timeout: 150)
            let sig = flags.take()
            if sig.contains(.stop) { break }
            if sig.contains(.changed) { reload() }
            for key in BoardModel.keys(input) where running { running = apply(key) }
            if !input.isEmpty || !sig.isEmpty { draw() }
        }
        withExtendedLifetime(watcher) {}
        term.leave()
        return 0
    }
}

/// Raw mode, alternate screen, signals. `leave()` always puts the terminal back.
final class BoardTerminal {
    struct Flag: OptionSet { let rawValue: Int; static let changed = Flag(rawValue: 1), stop = Flag(rawValue: 2), resize = Flag(rawValue: 4) }

    final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Flag = []
        func set(_ f: Flag) { lock.lock(); value.insert(f); lock.unlock() }
        func take() -> Flag { lock.lock(); defer { lock.unlock() }; let v = value; value = []; return v }
        var current: Flag { lock.lock(); defer { lock.unlock() }; return value }
    }

    private var saved = termios()
    private var active = false
    private var sources: [DispatchSourceSignal] = []
    let flags = Flags()

    init?() {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
    }

    func enter() {
        var raw = saved
        cfmakeraw(&raw)
        raw.c_oflag = saved.c_oflag    // keep "\n" handling: the board writes "\r\n" itself anyway
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        active = true
        for s in [SIGINT, SIGTERM, SIGHUP, SIGWINCH] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
            src.setEventHandler { [flags] in flags.set(s == SIGWINCH ? .resize : .stop) }
            src.resume()
            sources.append(src)
        }
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func leave() {
        guard active else { return }
        active = false
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        sources.forEach { $0.cancel() }
        sources = []
        for s in [SIGINT, SIGTERM, SIGHUP, SIGWINCH] { signal(s, SIG_DFL) }
    }

    deinit { leave() }

    private func write(_ s: String) {
        fputs(s, stdout)
        fflush(stdout)
    }

    func size() -> (Int, Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 { return (Int(ws.ws_col), Int(ws.ws_row)) }
        return (80, 24)
    }

    /// Bytes available within `timeout` ms (empty — nothing came or stdin is closed by a signal).
    func read(timeout: Int32) -> [UInt8] {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeout) > 0, p.revents & Int16(POLLIN) != 0 else {
            if p.revents & Int16(POLLHUP | POLLERR) != 0 { flags.set(.stop) }
            return []
        }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 { flags.set(.stop); return [] }
        return Array(buf.prefix(n))
    }
}
