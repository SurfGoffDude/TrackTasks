import Foundation

/// Which worktrees may go away by themselves. A task's repositories are decided together: whatever protects one
/// protects all. A fact that is missing protects too.
public enum WorktreeCleanup {
    public enum Protection: String, CaseIterable, Codable, Sendable {
        case working, waiting, busy, openPR, unmerged, pinned, terminal, server, remote, unfinished, rollback, offBranch

        /// The person may confirm removal in spite of it: the snapshot keeps the commits.
        public var overridable: Bool { self == .unmerged || self == .pinned }

        public var title: String {
            switch self {
            case .working: "агент работает"
            case .waiting: "ждёт очереди, ответа или решения"
            case .busy: "идёт операция с веткой"
            case .openPR: "открыт PR"
            case .unmerged: "есть неслитые коммиты"
            case .pinned: "закреплён"
            case .terminal: "открыт терминал"
            case .server: "работает сервер"
            case .remote: "результат на SSH-сервере не забран"
            case .unfinished: "не завершено слияние или перенос"
            case .rollback: "откат не закоммичен"
            case .offBranch: "HEAD не на ветке"
            }
        }

        var unknown: String {
            switch self {
            case .working, .waiting, .busy: "состояние задачи неизвестно"
            case .openPR: "неизвестно, есть ли PR"
            case .unmerged: "неизвестно, слита ли ветка"
            case .pinned: "закрепления не прочитаны"
            case .terminal: "неизвестно, открыт ли терминал"
            case .server: "неизвестно, работает ли сервер"
            case .remote: "неизвестно состояние SSH-сервера"
            case .unfinished, .rollback, .offBranch: "git не ответил"
            }
        }
    }

    /// true — protects, false — doesn't, missing — unknown.
    public typealias Facts = [Protection: Bool]

    public struct Member: Equatable, Sendable {
        public var path: String
        public var facts: Facts
        public init(path: String, facts: Facts) { self.path = path; self.facts = facts }
    }

    /// All worktrees of one task.
    public struct Group: Equatable, Sendable {
        public var members: [Member]
        /// nil = unknown.
        public var activity: Date?
        public init(members: [Member], activity: Date?) { self.members = members; self.activity = activity }
    }

    /// 0 = off.
    public struct Settings: Equatable, Sendable {
        public var maxCount: Int
        public var maxAgeDays: Int
        public init(maxCount: Int = 0, maxAgeDays: Int = 0) { self.maxCount = maxCount; self.maxAgeDays = maxAgeDays }
        public var enabled: Bool { maxCount > 0 || maxAgeDays > 0 }
    }

    public struct Block: Equatable, Hashable, Sendable {
        public var protection: Protection
        public var known: Bool
        public init(protection: Protection, known: Bool) { self.protection = protection; self.known = known }
        public var text: String { known ? protection.title : protection.unknown }
    }

    public enum Verdict: Equatable, Sendable {
        case keep(String)
        case remove(String)
        public var removes: Bool { if case .remove = self { true } else { false } }
        public var reason: String { switch self { case .keep(let s), .remove(let s): s } }
    }

    /// `overriding`: confirmed by the person; only what is known and overridable counts.
    public static func blocks(_ g: Group, overriding: Set<Protection> = []) -> [Block] {
        var out: [Block] = []
        for p in Protection.allCases {
            let values = g.members.map { $0.facts[p] }
            if values.contains(true) {
                if !(p.overridable && overriding.contains(p)) { out.append(Block(protection: p, known: true)) }
            }
            if values.isEmpty || values.contains(nil) { out.append(Block(protection: p, known: false)) }
        }
        return out
    }

    public static func text(_ blocks: [Block]) -> String {
        var seen = Set<String>()
        return blocks.map(\.text).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// The verdict of every worktree by its path. `queueRead` false: nothing is known about the tasks, all stay.
    /// «At most N» counts tasks, protected ones too.
    public static func decide(_ groups: [Group], _ s: Settings, now: Date, queueRead: Bool = true) -> [String: Verdict] {
        var out: [String: Verdict] = [:]
        func set(_ g: Group, _ v: Verdict) { for m in g.members { out[m.path] = v } }
        var free: [Group] = []
        for g in groups {
            let b = blocks(g)
            if !b.isEmpty { set(g, .keep(text(b))) }
            else if g.activity == nil { set(g, .keep("неизвестно, когда с ним работали")) }
            else if !queueRead { set(g, .keep("очередь не прочитана")) }
            else if !s.enabled { set(g, .keep("автоуборка выключена")) }
            else { free.append(g) }
        }
        free.sort {
            let a = $0.activity ?? now, b = $1.activity ?? now
            return a != b ? a < b : ($0.members.first?.path ?? "") < ($1.members.first?.path ?? "")
        }
        var left = groups.count
        for g in free {
            let age = now.timeIntervalSince(g.activity ?? now)
            if s.maxAgeDays > 0, age > Double(s.maxAgeDays) * 86400 {
                set(g, .remove("старше \(s.maxAgeDays) дн."))
                left -= 1
            } else if s.maxCount > 0, left > s.maxCount {
                set(g, .remove("задач с worktree больше \(s.maxCount)"))
                left -= 1
            } else {
                set(g, .keep("в пределах настроек"))
            }
        }
        return out
    }
}
