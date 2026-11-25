import Foundation

/// What CI says about the commit the app pushed.
public enum CIVerdict: String, Sendable {
    /// `confirming`: green once, the same answer is needed again. `wrongCommit`: the checks belong to another commit.
    case unknown, wrongCommit, red, running, none, confirming, green
}

/// A finished green set of checks: right after a push the first one may be incomplete, so it counts once seen again.
public struct CIConfirmation: Codable, Sendable, Equatable {
    /// Requests closer than this are one answer: GitHub may not have registered the checks yet.
    public static let pause: TimeInterval = 30

    public var headOid: String
    /// Sorted; a re-run has other times, so it is another set.
    public var checks: [String]
    /// When the set was first received.
    public var seen: Date
    public var confirmed: Bool

    /// `asked`: when the request was sent. A request sent before the first answer came (two at once) proves nothing.
    public static func next(_ old: CIConfirmation?, status: PullRequestStatus?, pushed: String, asked: Date) -> CIConfirmation? {
        guard let s = status, s.ci == .green, !pushed.isEmpty, s.headOid == pushed else { return nil }
        let fresh = CIConfirmation(headOid: s.headOid, checks: s.checkSet, seen: s.updated, confirmed: false)
        // Received before the first one: the clock was set back.
        guard var c = old, c.headOid == fresh.headOid, c.checks == fresh.checks, c.confirmed || s.updated >= c.seen else { return fresh }
        if asked.timeIntervalSince(c.seen) >= pause { c.confirmed = true }
        return c
    }
}

extension PullRequestStatus {
    public var checkSet: [String] {
        checks.map { [$0.name, $0.state.rawValue, $0.link ?? "", $0.started ?? "", $0.completed ?? ""].joined(separator: "\n") }.sorted()
    }
}

extension PullRequestLink {
    public var ci: CIVerdict {
        guard let s = status else { return .unknown }
        guard !pushedOid.isEmpty, s.headOid == pushedOid else { return .wrongCommit }
        switch s.ci {
        case .red: return .red
        case .running: return .running
        case .none: return .none
        case .green:
            guard let c = confirmation, c.confirmed, c.headOid == s.headOid, c.checks == s.checkSet else { return .confirming }
            return .green
        }
    }

    /// Why not to merge. Red of another commit still warns: it may be the one GitHub would merge.
    public var ciWarning: String? {
        guard let s = status, s.ci == .red else { return nil }
        return ci == .red ? "CI красный — \(s.failedNames)"
            : "CI красный на другом коммите (\(s.headOid.prefix(8))) — \(s.failedNames)"
    }

    /// An answer of GitHub; `status` nil = checks unavailable.
    public mutating func update(pr: PullRequest, status: PullRequestStatus?, asked: Date) {
        self.pr = pr
        self.status = status
        confirmation = .next(confirmation, status: status, pushed: pushedOid, asked: asked)
    }
}
