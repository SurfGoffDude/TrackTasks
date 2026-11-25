import Foundation

/// The lines of a check's output that say what is wrong: compiler errors and failed tests, without colors and build commands.
public enum VerifyErrors {
    public static func lines(_ output: String, limit: Int = 20) -> [String] {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        var seen = Set<String>()
        var out: [String] = []
        for raw in plain.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            // Compiler excerpts (`| \`- error:`) repeat the located line; command dumps are long.
            guard l.count < 400, !l.hasPrefix("|"), !l.hasPrefix("error: SwiftCompile"), l != "error: Build failed", l != "error: fatalError" else { continue }
            guard l.contains(": error:") || l.hasPrefix("error:") || l.hasPrefix("✘") || l.hasPrefix("FAIL") else { continue }
            if seen.insert(l).inserted { out.append(l) }
            if out.count == limit { break }
        }
        return out
    }

    /// End of the output with the errors in front: in a long build log they are far from the end.
    public static func tail(_ output: String, limit: Int) -> String {
        guard output.count > limit else { return output }
        let errors = lines(output).joined(separator: "\n")
        return (errors.isEmpty ? "" : errors + "\n") + "…\n" + String(output.suffix(limit))
    }
}
