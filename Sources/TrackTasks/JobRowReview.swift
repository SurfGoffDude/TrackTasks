import SwiftUI
import TrackTasksCore

extension JobRow {
    /// `main`: the card's main button does the fix.
    @ViewBuilder
    func reviewBlock(_ fix: JobOffer?, main: Bool) -> some View {
        if let v = job.verdict {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(v == .ok ? "Ревью: можно сливать" : (job.reviewFixed ? "Ревью: замечания исправлены" : "Ревью: есть замечания"),
                          systemImage: v == .ok || job.reviewFixed ? "checkmark.bubble.fill" : "exclamationmark.bubble.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(v == .ok || job.reviewFixed ? .green : .orange)
                    Spacer()
                    Button(showReview ? "Скрыть" : "Показать") { withAnimation(.snappy) { showReview.toggle() } }
                        .buttonStyle(.glass).controlSize(.small)
                    if let fix, !main {
                        Button(fix.title) { store.jobs.requestFix(job) }
                            .buttonStyle(.glass).controlSize(.small)
                            .disabled(fix.blocked != nil)
                    }
                }
                if let why = fix?.blocked, !main { Text("Исправить замечания пока нельзя: \(why)").font(.caption).foregroundStyle(.secondary) }
                if showReview {
                    MarkdownView(text: job.review)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                }
            }
        }
    }
}
