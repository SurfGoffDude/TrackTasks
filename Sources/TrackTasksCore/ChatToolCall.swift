import Foundation

/// A tool call as the chat shows and saves it: cut to size, without keys.
public struct ChatToolCall: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, done, failed, interrupted }

    public var id: String
    public var name: String
    /// Command, file or input.
    public var detail: String
    /// The call (a subagent) this one was made in.
    public var parent: String?
    public var result: String?
    public var state: State

    public static let detailLimit = 4000
    public static let resultLimit = 8000
    /// Results kept in one saved chat: every chat of a folder is read when its panel opens.
    public static let savedLimit = 200_000

    public init(id: String, name: String, detail: String, parent: String? = nil, result: String? = nil, state: State = .running) {
        self.id = id; self.name = name; self.detail = detail; self.parent = parent; self.result = result; self.state = state
    }

    public static func detail(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String { input[k] as? String ?? "" }
        func edit(_ e: [String: Any]) -> String {
            func lines(_ k: String, _ mark: String) -> [String] {
                let t = e[k] as? String ?? ""
                return t.isEmpty ? [] : t.prefix(detailLimit).components(separatedBy: "\n").map { mark + $0 }
            }
            return (lines("old_string", "- ") + lines("new_string", "+ ")).joined(separator: "\n")
        }
        let text: String
        switch tool {
        case "Bash": text = s("command")
        case "Read": text = s("file_path")
        case "Write": text = s("file_path") + "\n\n" + s("content").prefix(detailLimit * 2)
        case "Edit": text = s("file_path") + "\n\n" + edit(input)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            text = s("file_path") + "\n\n" + edits.map(edit).joined(separator: "\n\n")
        default:
            text = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { input.isEmpty ? "" : String(data: $0, encoding: .utf8) } ?? ""
        }
        return clean(text, limit: detailLimit)
    }

    /// `content` of `tool_result`: a string or a list of blocks.
    public static func result(_ content: Any?) -> String {
        if let t = content as? String { return clean(t, limit: resultLimit) }
        let blocks = (content as? [[String: Any]] ?? []).map { b -> String in
            switch b["type"] as? String {
            case "text": b["text"] as? String ?? ""
            case "image": "[изображение]"
            case let other: "[\(other ?? "данные")]"
            }
        }
        return clean(blocks.joined(separator: "\n"), limit: resultLimit)
    }

    /// Keys are removed before the cut: half a key isn't recognized.
    public static func clean(_ text: String, limit: Int) -> String {
        let t = Redactor().clean(String(text.prefix(limit * 2))).text
        return t.count > limit || text.count > limit * 2 ? t.prefix(limit) + "\n… обрезано" : t
    }
}
