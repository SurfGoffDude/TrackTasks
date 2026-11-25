import Foundation

/// What the person has chosen so far in the card «Claude спрашивает»; nothing is chosen for them.
public struct QuestionDraft: Equatable, Sendable {
    public enum Pick: Equatable, Sendable {
        case option(String)
        case own
        case decide
    }

    private var picks: [String: Pick] = [:]
    /// Kept when an option is picked instead, so nothing typed is lost.
    private var own: [String: String] = [:]
    /// The question the person went to; nil: the first one without an answer.
    private var shown: String?

    public init() {}

    /// Questions are known by text, as in the file; equal texts differ by order.
    public static func keys(_ texts: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return texts.map { t in
            let k = AgentQuestions.oneLine(t)
            seen[k, default: 0] += 1
            return seen[k] == 1 ? k : "\(k)\n\(seen[k]!)"
        }
    }

    public func pick(_ key: String) -> Pick? { picks[key] }
    public func ownText(_ key: String) -> String { own[key] ?? "" }

    public mutating func choose(_ key: String, _ pick: Pick) { picks[key] = pick }

    public mutating func type(_ key: String, _ text: String) {
        guard text != ownText(key) else { return }
        own[key] = text
        if !AgentQuestions.oneLine(text).isEmpty { picks[key] = .own }
        else if picks[key] == .own { picks[key] = nil }
    }

    /// The line for the file; nil while there is no answer.
    public func answer(_ key: String) -> String? {
        let s: String
        switch picks[key] {
        case .option(let t): s = AgentQuestions.oneLine(t)
        case .own: s = AgentQuestions.oneLine(ownText(key))
        case .decide: s = AgentQuestions.decideYourself
        case nil: return nil
        }
        return s.isEmpty ? nil : s
    }

    /// Index of the question to show; 0 for an empty list.
    public func current(_ keys: [String]) -> Int {
        if let shown, let i = keys.firstIndex(of: shown) { return i }
        return keys.firstIndex { answer($0) == nil } ?? max(0, keys.count - 1)
    }

    public mutating func go(_ step: Int, _ keys: [String]) {
        guard !keys.isEmpty else { return }
        shown = keys[min(max(0, current(keys) + step), keys.count - 1)]
    }

    public func isReady(_ keys: [String]) -> Bool { !keys.isEmpty && keys.allSatisfy { answer($0) != nil } }

    /// The first question left without an answer.
    public func missing(_ keys: [String]) -> Int? { keys.firstIndex { answer($0) == nil } }

    public func answers(_ texts: [String]) -> [(question: String, answer: String)] {
        zip(texts, Self.keys(texts)).compactMap { t, k in answer(k).map { (t, $0) } }
    }
}

/// What the questions of a task want from the person.
public enum QuestionStatus: Equatable, Sendable {
    case none
    /// Open questions.
    case ask(Int)
    /// Answered in the file, but the agent doesn't have the answers; or the record was damaged.
    case send

    /// `busy`: the answers are being sent or the agent works. `closed`: cancelled, merged or not the latest run.
    public static func of(open: Int, undelivered: Bool, busy: Bool, closed: Bool) -> QuestionStatus {
        if busy || closed { return .none }
        if open > 0 { return .ask(open) }
        return undelivered ? .send : .none
    }

    public var needsPerson: Bool { self != .none }

    public var line: String {
        switch self {
        case .none: ""
        case .ask(let n): "Ждёт ответа: \(n)"
        case .send: "Ответы не переданы агенту"
        }
    }

    /// Counter of tasks for the queue and the sidebar; nil when nobody waits.
    public static func counter(_ all: [QuestionStatus]) -> String? {
        let n = all.filter(\.needsPerson).count
        return n > 0 ? "Ждут ответа: \(n)" : nil
    }
}
