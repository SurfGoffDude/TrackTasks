import Foundation

/// The chat's input field: `@file` and `/command` in the text, suggestions for both.
/// The field doesn't tell where its cursor is, so suggestions work at the end of the text.
public enum ChatInput {
    // MARK: @file

    /// `@…` being typed at the end of the text.
    public struct FileToken: Equatable, Sendable {
        /// From `@` to the end of the text.
        public var range: Range<String.Index>
        public var query: String
    }

    /// `@` counts only at the start or after a space: «a@b.c» is an e-mail. A name with spaces is typed as `@"a b`.
    public static func fileToken(_ text: String) -> FileToken? {
        var from = text.endIndex
        while let at = text[..<from].lastIndex(of: "@") {
            from = at
            if at != text.startIndex, !text[text.index(before: at)].isWhitespace { continue }
            let tail = text[text.index(after: at)...]
            if tail.first == "\"" {
                let q = tail.dropFirst()
                return q.contains(where: { $0 == "\"" || $0.isNewline }) ? nil : FileToken(range: at..<text.endIndex, query: String(q))
            }
            return tail.contains(where: \.isWhitespace) ? nil : FileToken(range: at..<text.endIndex, query: String(tail))
        }
        return nil
    }

    /// The text with the token replaced by the path and a space after it.
    public static func insert(_ path: String, in text: String, at token: FileToken) -> String {
        let p = path.contains(where: \.isWhitespace) ? "@\"\(path)\" " : "@\(path) "
        return text.replacingCharacters(in: token.range, with: p)
    }

    /// Beginning of the file's name, then of the path, then any place of the name, then of the path;
    /// shorter paths first. An empty query gives the first files as they are.
    public static func rank(_ files: [String], query: String, limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(files.prefix(limit)) }
        let found: [(rank: Int, path: String)] = files.compactMap { f in
            let path = f.lowercased()
            guard path.contains(q) else { return nil }
            let name = (path as NSString).lastPathComponent
            let rank = name.hasPrefix(q) ? 0 : path.hasPrefix(q) ? 1 : name.contains(q) ? 2 : 3
            return (rank, f)
        }
        return found.sorted { ($0.rank, $0.path.count, $0.path) < ($1.rank, $1.path.count, $1.path) }
            .prefix(limit).map(\.path)
    }

    // MARK: /command

    public struct Command: Equatable, Sendable, Identifiable {
        /// Without `/`.
        public var name: String
        public var hint: String
        /// Values the argument may have; [] = no argument.
        public var values: [String]
        public var id: String { name }
        public init(_ name: String, _ hint: String, values: [String] = []) {
            self.name = name; self.hint = hint; self.values = values
        }
    }

    /// nil: ordinary text (also an unknown command: it may be Claude's own, and a path such as `/Users/…`).
    public static func parse(_ text: String, commands: [Command]) -> (command: Command, argument: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        let name = t.dropFirst().prefix { !$0.isWhitespace }
        guard let c = commands.first(where: { $0.name == name.lowercased() }) else { return nil }
        return (c, t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public struct Completion: Equatable, Sendable {
        /// Text of the field once chosen.
        public var text: String
        public var hint: String
        /// Complete: may be run as it is.
        public var runs: Bool
    }

    /// Commands, or the values of the typed command's argument.
    public static func completions(_ text: String, commands: [Command]) -> [Completion] {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return [] }
        let typed = text.dropFirst().lowercased()
        guard let space = typed.firstIndex(where: \.isWhitespace) else {
            return commands.filter { $0.name.hasPrefix(typed) }
                .map { Completion(text: "/" + $0.name + ($0.values.isEmpty ? "" : " "), hint: $0.hint, runs: $0.values.isEmpty) }
        }
        guard let c = commands.first(where: { $0.name == typed[..<space] }) else { return [] }
        let arg = typed[space...].trimmingCharacters(in: .whitespaces)
        return c.values.filter { $0.hasPrefix(arg) }
            .map { Completion(text: "/\(c.name) \($0)", hint: c.hint, runs: true) }
    }

    /// Command name for a button: «Обнови about.md» → «обнови-about.md».
    public static func slug(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    // MARK: Context

    /// «41k · 21 %»; the share only when the model's window is known.
    public static func context(_ tokens: Int, window: Int?) -> String {
        let t = tokens < 1000 ? "\(tokens)" : "\((tokens + 500) / 1000)k"
        guard let window, window > 0 else { return t }
        return "\(t) · \(Int((Double(tokens) / Double(window) * 100).rounded())) %"
    }
}
