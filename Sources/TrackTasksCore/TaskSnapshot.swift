import Foundation

public struct SessionMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, agent }
    public var role: Role
    public var text: String
    public init(_ role: Role, _ text: String) { self.role = role; self.text = text }
}

/// Conversation of a job as markdown. Not cleaned: pass it through `Redactor`.
public struct TaskSnapshot: Sendable {
    public var title: String
    public var project: String
    /// "Выполнение · Claude · Opus · $0.12" etc.
    public var facts: [String]
    public var messages: [SessionMessage]
    public var review: String
    /// The session file was not found: only what the queue remembers.
    public var partial: Bool

    public init(title: String, project: String, facts: [String] = [], messages: [SessionMessage],
                review: String = "", partial: Bool = false) {
        self.title = title; self.project = project; self.facts = facts
        self.messages = messages; self.review = review; self.partial = partial
    }

    public var markdown: String {
        var out = ["# \(title)", ([project] + facts).filter { !$0.isEmpty }.joined(separator: " · ")]
        if partial { out.append("_Файл сессии не найден: здесь только то, что сохранила очередь._") }
        for m in messages {
            out.append("## " + (m.role == .user ? "Пользователь" : "Агент"))
            out.append(m.text)
        }
        if !review.isEmpty { out += ["## Ревью", review] }
        return out.joined(separator: "\n\n") + "\n"
    }
}

/// A secret gist made by the app.
public struct GistLink: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var job: UUID
    public var title: String
    public var date: Date

    public init(id: String, url: String, job: UUID, title: String, date: Date = Date()) {
        self.id = id; self.url = url; self.job = job; self.title = title; self.date = date
    }
}

/// `gh api` calls for gists: github.com only, whatever host `gh` uses by default.
public enum GistAPI {
    public static let fileName = "task.md"

    public static let createArgs = ["api", "--hostname", "github.com", "--method", "POST", "gists", "--input", "-"]

    /// `public` is always false. No description: the title may be private.
    public static func createBody(_ text: String) -> String {
        let obj: [String: Any] = ["public": false, "files": [fileName: ["content": text]]]
        return (try? JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func parseCreated(_ out: String) -> (id: String, url: String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
              let id = o["id"] as? String, isID(id), let url = o["html_url"] as? String else { return nil }
        return (id, url)
    }

    /// nil = not an id of a gist (the id becomes a part of the request path).
    public static func deleteArgs(_ id: String) -> [String]? {
        isID(id) ? ["api", "--hostname", "github.com", "--method", "DELETE", "gists/\(id)"] : nil
    }

    private static func isID(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil }
}
