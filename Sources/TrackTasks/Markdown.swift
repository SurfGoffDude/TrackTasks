import SwiftUI

// Parsing lives in TrackTasksCore (MD, MDBlock); here only rendering.

extension MD {
    static func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

struct MarkdownView: View {
    private let blocks: [MDBlock]
    private let taskIndex: [Int: Int]
    private let onToggle: ((Int) -> Void)?
    private let roomy: Bool

    /// `onToggle` makes checkboxes clickable (gets the checkbox ordinal). `roomy` = document style, bigger spacing.
    init(text: String, hideH1: Bool = false, roomy: Bool = false, onToggle: ((Int) -> Void)? = nil) {
        blocks = MD.cachedParse(text, hideH1: hideH1)
        var idx: [Int: Int] = [:]
        var k = 0
        for (i, b) in blocks.enumerated() { if case .task = b { idx[i] = k; k += 1 } }
        taskIndex = idx
        self.onToggle = onToggle
        self.roomy = roomy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: roomy ? 10 : 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b, at: i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ b: MDBlock, at i: Int) -> some View {
        switch b {
        case .heading(let level, let t):
            if roomy {
                VStack(alignment: .leading, spacing: 4) {
                    MD.inline(t)
                        .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                    if level <= 2 { Divider().opacity(0.6) }
                }
                .padding(.top, 6)
            } else {
                MD.inline(t)
                    .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.weight(.semibold))
                    .padding(.top, 4)
            }
        case .paragraph(let t):
            MD.inline(t).fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let t):
            item(indent: indent, marker: Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary), t)
        case .ordered(let indent, let n, let t):
            item(indent: indent, marker: Text("\(n).").monospacedDigit().foregroundStyle(.secondary), t)
        case .task(let indent, let done, let t):
            if let onToggle, let n = taskIndex[i] {
                Button { withAnimation(.snappy) { onToggle(n) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .font(.body.weight(.medium))
                            .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            .contentTransition(.symbolEffect(.replace))
                        MD.inline(t)
                            .strikethrough(done, color: .secondary)
                            .foregroundStyle(done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.primary.opacity(done ? 0.025 : 0.05), in: .rect(cornerRadius: 9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(indent) * 18)
                .help(done ? "Снять отметку" : "Отметить выполненным")
            } else {
                item(indent: indent,
                     marker: Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)),
                     t)
            }
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c)
                    .font(.callout.monospaced())
                    .fixedSize()
                    .padding(10)
            }
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        case .quote(let t):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                MD.inline(t).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            MDTable(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func item(indent: Int, marker: Text, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            MD.inline(t).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }
}

/// Table that keeps columns readable in a narrow panel: cells wrap, the table scrolls sideways if needed.
struct MDTable: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    private func widths() -> [CGFloat] {
        (0..<columns).map { c in
            let longest = ([header] + rows).map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0
            return min(230, max(56, CGFloat(longest) * 7 + 16))
        }
    }

    var body: some View {
        let w = widths()
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(header, c, width: w[c]).fontWeight(.semibold)
                    }
                }
                .background(.primary.opacity(0.07))
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    Divider().opacity(0.5)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(row, c, width: w[c])
                        }
                    }
                    .background(r.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
        }
    }

    private func cell(_ row: [String], _ c: Int, width: CGFloat) -> some View {
        MD.inline(row.indices.contains(c) ? row[c] : "")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}
