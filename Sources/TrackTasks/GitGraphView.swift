import SwiftUI
import TrackTasksCore

struct GitCommitRow: View {
    let commit: GitCommit
    let row: GitGraphRow
    let graphWidth: CGFloat
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            GitGraphCell(row: row, merge: commit.isMerge)
                .frame(width: graphWidth, height: GitGraphCell.height)
                .clipped()
            ForEach(commit.labels, id: \.self) { l in
                Text(l.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .foregroundStyle(color(l.kind))
                    .background(color(l.kind).opacity(0.15), in: .capsule)
                    .frame(maxWidth: 180)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(commit.subject).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(commit.author).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 140, alignment: .trailing)
            Text(commit.date.formatted(date: .numeric, time: .shortened))
                .foregroundStyle(.secondary).monospacedDigit().fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: GitGraphCell.height)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(.rect)
        .help(commit.subject)
    }

    private func color(_ k: GitCommit.Label.Kind) -> Color {
        switch k {
        case .head: .red
        case .branch: .green
        case .remote: .blue
        case .tag: .orange
        }
    }
}

/// One row of the graph; rows touch each other, so the lines join.
struct GitGraphCell: View {
    static let height: CGFloat = 26
    static let step: CGFloat = 14
    static let maxLanes = 20

    let row: GitGraphRow
    let merge: Bool

    static func width(_ rows: [GitGraphRow]) -> CGFloat {
        CGFloat(min(rows.map(\.width).max() ?? 1, maxLanes)) * step
    }

    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo]
    private func color(_ lane: Int) -> Color { Self.colors[lane % Self.colors.count] }
    private func x(_ lane: Int) -> CGFloat { (CGFloat(lane) + 0.5) * Self.step }

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let node = CGPoint(x: x(row.column), y: mid)
            func line(_ from: CGPoint, _ to: CGPoint, _ c: Color) {
                var p = Path()
                p.move(to: from)
                p.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2), control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
                ctx.stroke(p, with: .color(c), lineWidth: 1.6)
            }
            for l in row.passing { line(CGPoint(x: x(l), y: 0), CGPoint(x: x(l), y: size.height), color(l)) }
            for l in row.incoming { line(CGPoint(x: x(l), y: 0), node, color(l)) }
            for e in row.outgoing { line(node, CGPoint(x: x(e.lane), y: size.height), color(e.lane)) }
            let r: CGFloat = merge ? 3 : 4
            let dot = Path(ellipseIn: CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(color(row.column)))
        }
        .accessibilityHidden(true)
    }
}
