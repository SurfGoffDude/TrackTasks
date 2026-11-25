import SwiftUI
import AppKit
import TrackTasksCore

/// Request to show a line; every click on a comment is a new one.
struct DiffGoTo: Equatable {
    let id = UUID()
    let fileID: String
    let side: DiffComment.Side
    let line: Int
}

/// Lines of one file. NSTableView with a fixed row height draws only visible rows, so size doesn't matter.
struct DiffTableView: NSViewRepresentable {
    let table: DiffTable
    /// Changes when the rows do; a new `fileID` also scrolls to the top.
    let version: Int
    let fileID: String
    /// Строки с комментариями (`DiffComments.marks`); меняется вместе с `marksVersion`.
    var marks: [String: Bool] = [:]
    var marksVersion = 0
    var goTo: DiffGoTo?
    /// Контекстное меню «Комментировать»: выбранные строки.
    var onComment: (IndexSet) -> Void = { _ in }

    /// Выбранные строки: для кнопок над diff.
    var onSelect: (IndexSet) -> Void = { _ in }
    /// Контекстное меню «Отклонить кусок»: номер куска в файле. nil — сейчас нельзя.
    var onReject: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let t = DiffNSTable()
        t.headerView = nil
        t.style = .plain
        t.intercellSpacing = .zero
        t.rowHeight = DiffStyle.rowHeight
        t.usesAutomaticRowHeights = false
        t.columnAutoresizingStyle = .noColumnAutoresizing
        t.allowsMultipleSelection = true
        t.allowsColumnReordering = false
        t.backgroundColor = .textBackgroundColor
        let col = NSTableColumn(identifier: DiffStyle.cellID)
        col.minWidth = 100
        col.maxWidth = .greatestFiniteMagnitude
        t.addTableColumn(col)
        t.dataSource = context.coordinator
        t.delegate = context.coordinator
        t.copyText = { [weak c = context.coordinator] in c?.text(of: $0) ?? "" }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Комментировать строки…", action: #selector(Coordinator.comment(_:)), keyEquivalent: "")
        item.target = context.coordinator
        menu.addItem(item)
        let reject = NSMenuItem(title: "Отклонить кусок", action: #selector(Coordinator.reject(_:)), keyEquivalent: "")
        reject.target = context.coordinator
        menu.addItem(reject)
        t.menu = menu

        let s = NSScrollView()
        s.documentView = t
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        s.contentView.postsFrameChangedNotifications = true
        context.coordinator.scroll = s
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized),
                                               name: NSView.frameDidChangeNotification, object: s.contentView)
        return s
    }

    func updateNSView(_ s: NSScrollView, context: Context) {
        let c = context.coordinator
        update(s, c)
        // The table of the requested file may come later.
        guard let g = goTo, g.id != c.shown, g.fileID == c.fileID, let t = s.documentView as? NSTableView else { return }
        c.shown = g.id
        guard let row = c.row(of: g) else { return }
        t.selectRowIndexes([row], byExtendingSelection: false)
        let y = t.rect(ofRow: row).midY - s.contentView.bounds.height / 2
        let top = max(0, min(y, t.frame.height - s.contentView.bounds.height))
        s.contentView.scroll(to: NSPoint(x: s.contentView.bounds.minX, y: top))
        s.reflectScrolledClipView(s.contentView)
    }

    private func update(_ s: NSScrollView, _ c: Coordinator) {
        c.onComment = onComment
        c.onReject = onReject
        c.onSelect = onSelect
        guard let t = s.documentView as? NSTableView else { return }
        if c.version == version, c.marksVersion != marksVersion {
            // Only the markers changed: keep selection and scroll position.
            c.marksVersion = marksVersion
            c.marks = marks
            let sel = t.selectedRowIndexes
            t.reloadData()
            t.selectRowIndexes(sel, byExtendingSelection: false)
            return
        }
        guard c.version != version else { return }
        c.marksVersion = marksVersion
        c.marks = marks
        let newFile = c.fileID != fileID
        c.version = version
        c.fileID = fileID
        c.table = table
        t.deselectAll(nil)
        t.reloadData()
        c.resized()
        if newFile {
            s.contentView.scroll(to: .zero)
            s.reflectScrolledClipView(s.contentView)
        }
    }

    static func dismantleNSView(_ s: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        var table = DiffTable()
        var version = -1
        var fileID = ""
        var marks: [String: Bool] = [:]
        var marksVersion = 0
        var onComment: (IndexSet) -> Void = { _ in }
        var onReject: ((Int) -> Void)?
        var onSelect: (IndexSet) -> Void = { _ in }
        weak var scroll: NSScrollView?
        /// The last `DiffGoTo` done.
        var shown: UUID?

        func row(of g: DiffGoTo) -> Int? {
            func hit(_ l: DiffLine?) -> Bool {
                guard let l, l.kind != .noNewline else { return false }
                return (g.side == .old ? l.oldNumber : l.newNumber) == g.line
            }
            return table.rows.firstIndex {
                switch $0 {
                case .hunk: false
                case .line(let l): hit(l)
                case .pair(let a, let b): hit(a) || hit(b)
                }
            }
        }

        @objc func resized() {
            guard let s = scroll, let col = (s.documentView as? NSTableView)?.tableColumns.first else { return }
            let w = max(s.contentView.bounds.width, DiffStyle.contentWidth(table))
            if abs(col.width - w) > 0.5 { col.width = w }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // Also sent while SwiftUI updates the table: its state can't change then.
            DispatchQueue.main.async { [weak self] in
                guard let self, let t = self.scroll?.documentView as? NSTableView else { return }
                self.onSelect(t.selectedRowIndexes)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { table.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard table.rows.indices.contains(row) else { return nil }
            let v = tableView.makeView(withIdentifier: DiffStyle.cellID, owner: nil) as? DiffCell ?? DiffCell()
            v.identifier = DiffStyle.cellID
            v.set(table.rows[row], gutter: DiffStyle.gutter(table), mark: mark(of: table.rows[row]))
            return v
        }

        /// nil — без комментария; false — есть; true — комментарий устарел.
        private func mark(of row: DiffRow) -> Bool? {
            if marks.isEmpty { return nil }
            func key(_ l: DiffLine) -> String? {
                if l.kind == .noNewline { return nil }
                if l.kind == .removed { return l.oldNumber.map { DiffComments.key(.old, $0) } }
                return l.newNumber.map { DiffComments.key(.new, $0) }
            }
            switch row {
            case .hunk: return nil
            case .line(let l): return key(l).flatMap { marks[$0] }
            case .pair(let a, let b):
                if let b, b.kind != .removed { return key(b).flatMap { marks[$0] } }
                return a.flatMap(key).flatMap { marks[$0] }
            }
        }

        @objc func comment(_ sender: Any?) {
            guard let t = scroll?.documentView as? NSTableView else { return }
            var rows = t.selectedRowIndexes
            if t.clickedRow >= 0, !rows.contains(t.clickedRow) { rows = [t.clickedRow] }
            if !rows.isEmpty { onComment(rows) }
        }

        /// The hunk of the clicked row (the selection doesn't matter: exactly one hunk is rejected).
        private var clickedHunk: Int? {
            guard let t = scroll?.documentView as? NSTableView, t.clickedRow >= 0 else { return nil }
            return table.hunk(of: [t.clickedRow])
        }

        @objc func reject(_ sender: Any?) {
            if let h = clickedHunk { onReject?(h) }
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            item.action == #selector(reject(_:)) ? onReject != nil && clickedHunk != nil : true
        }

        func text(of rows: IndexSet) -> String {
            rows.compactMap { i -> String? in
                guard table.rows.indices.contains(i) else { return nil }
                switch table.rows[i] {
                case .hunk: return nil
                case .line(let l): return l.kind == .noNewline ? nil : l.text
                case .pair(let a, let b): return (b ?? a).flatMap { $0.kind == .noNewline ? nil : $0.text }
                }
            }.joined(separator: "\n")
        }
    }
}

/// ⌘C copies the text of selected lines.
private final class DiffNSTable: NSTableView {
    var copyText: ((IndexSet) -> String)?

    @objc func copy(_ sender: Any?) {
        guard let s = copyText?(selectedRowIndexes), !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
private enum DiffStyle {
    static let cellID = NSUserInterfaceItemIdentifier("diff")
    static let rowHeight: CGFloat = 18
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let marker: CGFloat = 16

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        p.tabStops = []
        p.defaultTabInterval = charWidth * CGFloat(DiffRows.tab)
        return p
    }()
    static let rightAligned: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()

    /// Width of one line-number column.
    static func gutter(_ t: DiffTable) -> CGFloat {
        CGFloat(max(3, String(t.maxLineNumber).count)) * 7 + 12
    }

    static func contentWidth(_ t: DiffTable) -> CGFloat {
        let text = CGFloat(t.columns) * charWidth + marker + 16
        let isSplit = t.rows.contains { if case .pair = $0 { true } else { false } }
        return ceil(isSplit ? 2 * (text + gutter(t)) : text + 2 * gutter(t))
    }
}

private final class DiffCell: NSView {
    private var row = DiffRow.hunk("")
    private var gutter: CGFloat = 0
    private var mark: Bool?

    // Dynamic system colors are resolved in draw, so a theme switch just redraws.
    override var isFlipped: Bool { true }

    func set(_ row: DiffRow, gutter: CGFloat, mark: Bool?) {
        self.row = row
        self.gutter = gutter
        self.mark = mark
        clipsToBounds = true
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? {
        func say(_ l: DiffLine) -> String {
            (l.kind == .added ? "добавлено: " : l.kind == .removed ? "удалено: " : "") + l.text
        }
        switch row {
        case .hunk(let s): return s
        case .line(let l): return say(l)
        case .pair(let a, let b):
            if let a, a == b { return say(a) }
            return [a, b].compactMap { $0 }.map(say).joined(separator: "; ")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch row {
        case .hunk(let s):
            NSColor.systemBlue.withAlphaComponent(0.10).setFill()
            bounds.fill(using: .sourceOver)
            text(s, in: bounds.insetBy(dx: 10, dy: 0), color: .secondaryLabelColor)
        case .line(let l):
            side(l, in: bounds, numbers: [l.oldNumber, l.newNumber])
        case .pair(let a, let b):
            let half = floor(bounds.width / 2)
            let left = NSRect(x: 0, y: 0, width: half, height: bounds.height)
            let right = NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height)
            side(a, in: left, numbers: [a?.oldNumber])
            side(b, in: right, numbers: [b?.newNumber])
            NSColor.separatorColor.setFill()
            NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
        }
        if let mark {
            (mark ? NSColor.systemGray : NSColor.systemOrange).setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        }
    }

    private func side(_ line: DiffLine?, in r: NSRect, numbers: [Int?]) {
        guard let line else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.06).setFill()
            r.fill(using: .sourceOver)
            return
        }
        let tint: NSColor? = switch line.kind {
        case .added: .systemGreen
        case .removed: .systemRed
        case .context, .noNewline: nil
        }
        let gutters = gutter * CGFloat(numbers.count)
        if let tint {
            tint.withAlphaComponent(0.16).setFill()
            r.fill(using: .sourceOver)
            tint.withAlphaComponent(0.14).setFill()
            NSRect(x: r.minX, y: 0, width: gutters, height: r.height).fill(using: .sourceOver)
        }
        for (i, n) in numbers.enumerated() {
            guard let n else { continue }
            let box = NSRect(x: r.minX + gutter * CGFloat(i), y: 2, width: gutter - 6, height: r.height - 2)
            (String(n) as NSString).draw(in: box, withAttributes: [
                .font: DiffStyle.numberFont, .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: DiffStyle.rightAligned,
            ])
        }
        let mark = line.kind == .added ? "+" : line.kind == .removed ? "−" : line.kind == .noNewline ? "\\" : ""
        let x = r.minX + gutters
        if !mark.isEmpty {
            text(mark, in: NSRect(x: x + 4, y: 0, width: DiffStyle.marker, height: r.height), color: .labelColor)
        }
        let body = NSRect(x: x + DiffStyle.marker, y: 0, width: r.maxX - x - DiffStyle.marker, height: r.height)
        text(line.text, in: body, color: line.kind == .noNewline ? .secondaryLabelColor : .labelColor)
    }

    private func text(_ s: String, in r: NSRect, color: NSColor) {
        guard !s.isEmpty, r.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        r.clip()
        (s as NSString).draw(in: r.offsetBy(dx: 0, dy: 1), withAttributes: [
            .font: DiffStyle.font, .foregroundColor: color, .paragraphStyle: DiffStyle.paragraph,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
