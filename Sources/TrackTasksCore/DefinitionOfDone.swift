import Foundation

/// Project-wide «Definition of Done»: checklist in `## Definition of Done` of about.md,
/// added to the «Критерии готовности» of every NEW task (existing files are never touched).
public enum DefinitionOfDone {
    public static let heading = "Definition of Done"

    /// Items of the section of the project's about.md (empty when there is none).
    public static func items(inProject url: URL) -> [String] {
        guard let text = try? String(contentsOf: url.appendingPathComponent("about.md"), encoding: .utf8) else { return [] }
        return items(inAbout: text)
    }

    /// Items of the section (checkbox, bullets or numbered), in order, without duplicates.
    public static func items(inAbout text: String) -> [String] {
        let lines = Frontmatter.parse(text).body.components(separatedBy: "\n")
        guard let r = sectionRange(lines) else { return [] }
        var out: [String] = []
        for line in lines[r].dropFirst() {
            var s = line.trimmingCharacters(in: .whitespaces)
            for p in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ", "- ", "* "] where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)); break
            }
            if let m = s.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { s.removeSubrange(m) }
            s = s.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, !out.contains(where: { same($0, s) }) { out.append(s) }
        }
        return out
    }

    /// about.md with the section replaced by `items` (created at the end if missing, removed if empty).
    public static func setting(_ items: [String], inAbout text: String) -> String {
        let clean = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var lines = text.components(separatedBy: "\n")
        let bodyLines = Frontmatter.parse(text).body.components(separatedBy: "\n")
        let offset = max(0, lines.count - bodyLines.count)
        let block = clean.isEmpty ? [] : ["## \(heading)", ""] + clean.map { "- [ ] \($0)" }
        if let r = sectionRange(bodyLines) {
            let rep = block.isEmpty ? [] : block + (r.upperBound < bodyLines.count ? [""] : [])
            lines.replaceSubrange((r.lowerBound + offset)..<(r.upperBound + offset), with: rep)
            return lines.joined(separator: "\n")
        }
        guard !block.isEmpty else { return text }
        return text.trimmingCharacters(in: .newlines) + "\n\n" + block.joined(separator: "\n") + "\n"
    }

    /// Adds DoD items to the «Критерии готовности» of a NEW task body; items already there are skipped.
    public static func apply(_ items: [String], to body: String) -> String {
        var out = body
        for item in items {
            if MD.checklist(out, in: .criteria).contains(where: { same($0.text, item) }) { continue }
            out = MD.appendTask(out, item, in: .criteria)
        }
        return out
    }

    /// Lines [heading, end) of the `Definition of Done` section (exact heading, code fences skipped).
    private static func sectionRange(_ lines: [String]) -> Range<Int>? {
        var fence: String?
        var start: Int?, level = 0
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            let lv = t.prefix(while: { $0 == "#" }).count
            guard lv > 0, lv <= 6, t.dropFirst(lv).first == " " else { continue }
            if let st = start, lv <= level { return st..<i }
            if start == nil, t.dropFirst(lv).trimmingCharacters(in: .whitespaces).lowercased() == heading.lowercased() {
                start = i; level = lv
            }
        }
        return start.map { $0..<lines.count }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
