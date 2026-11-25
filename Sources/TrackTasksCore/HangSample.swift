import Foundation

/// Text of /usr/bin/sample cut down to what tells where a process is stuck.
public enum HangSample {
    /// Threads of "Call graph", without idle workers; of a deep stack the innermost frames are kept.
    public static func trim(_ sample: String, framesPerThread: Int = 25, limit: Int = 6000) -> String {
        guard let start = sample.range(of: "Call graph:\n") else { return String(sample.suffix(min(limit, 500))) }
        var body = sample[start.upperBound...]
        if let end = body.range(of: "\nTotal number in stack") { body = body[..<end.lowerBound] }
        var threads: [[String]] = []
        for raw in body.split(separator: "\n") {
            let l = raw.drop { " +!:|".contains($0) }
                .replacingOccurrences(of: #"\s+(load address \S+ \+ \S+\s*)?\[0x[0-9a-f,.x]+\]"#, with: "", options: .regularExpression)
            if l.range(of: #"^\d+ Thread_"#, options: .regularExpression) != nil { threads.append([l]) }
            else if !threads.isEmpty { threads[threads.count - 1].append(l) }
        }
        let busy = threads.filter { t in !(t.contains { $0.contains("__workq_kernreturn") } && t.count < 6) }
        // Every thread gets a share: one deep stack must not push out the rest.
        let share = max(limit / max(busy.count, 1), 300)
        let text = busy.map { t in
            let frames = t.dropFirst()
            let kept = frames.suffix(framesPerThread)
            let stack = (kept.count < frames.count ? ["…"] : []) + kept
            return t[0] + "\n" + String(stack.joined(separator: "\n").suffix(share))
        }.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
