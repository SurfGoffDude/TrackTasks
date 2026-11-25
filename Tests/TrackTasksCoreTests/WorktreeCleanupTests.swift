import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct WorktreeCleanupTests {
    typealias C = WorktreeCleanup
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var free: C.Facts { Dictionary(uniqueKeysWithValues: C.Protection.allCases.map { ($0, false) }) }
    func group(_ paths: String..., days: Double? = 100, facts: C.Facts? = nil) -> C.Group {
        .init(members: paths.map { .init(path: $0, facts: facts ?? free) }, activity: days.map { now.addingTimeInterval(-$0 * 86400) })
    }
    func removed(_ g: [C.Group], _ s: C.Settings, queueRead: Bool = true) -> [String] {
        C.decide(g, s, now: now, queueRead: queueRead).filter { $0.value.removes }.map(\.key).sorted()
    }

    @Test(arguments: C.Protection.allCases) func protects(_ p: C.Protection) {
        var f = free
        f[p] = true
        let g = group("a", facts: f)
        #expect(removed([g], .init(maxAgeDays: 1)).isEmpty)
        #expect(C.decide([g], .init(maxAgeDays: 1), now: now)["a"] == .keep(p.title))
        #expect(C.blocks(g, overriding: Set(C.Protection.allCases)).isEmpty == [.unmerged, .pinned].contains(p))
    }
    @Test(arguments: C.Protection.allCases) func unknownProtects(_ p: C.Protection) {
        var f = free
        f[p] = nil
        let g = group("a", facts: f)
        #expect(removed([g], .init(maxAgeDays: 1)).isEmpty)
        // Not even by hand.
        #expect(!C.blocks(g, overriding: Set(C.Protection.allCases)).isEmpty)
    }
    @Test func offByDefault() {
        #expect(!C.Settings().enabled)
        #expect(removed([group("a", days: 9999)], .init()).isEmpty)
    }
    @Test func unreadQueueKeepsAll() { #expect(removed([group("a")], .init(maxCount: 1, maxAgeDays: 1), queueRead: false).isEmpty) }
    @Test func unknownAgeKeeps() { #expect(removed([group("a", days: nil)], .init(maxAgeDays: 1)).isEmpty) }
    @Test func byAge() { #expect(removed([group("a", days: 8), group("b", days: 6)], .init(maxAgeDays: 7)) == ["a"]) }
    @Test func byCountOldestFirst() {
        #expect(removed([group("new", days: 1), group("old", days: 9), group("mid", days: 5)], .init(maxCount: 1)) == ["mid", "old"])
    }
    @Test func protectedCount() {
        var f = free
        f[.working] = true
        #expect(removed([group("w", days: 50, facts: f), group("a", days: 3), group("b", days: 1)], .init(maxCount: 2)) == ["a"])
    }
    @Test func groupIsWhole() {
        var f = free
        f[.server] = true
        var g = group("a", "b")
        #expect(removed([g], .init(maxAgeDays: 1)) == ["a", "b"])
        g.members[1].facts = f
        #expect(removed([g], .init(maxAgeDays: 1)).isEmpty)
    }
}
