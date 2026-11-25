import Testing
import Foundation
@testable import TrackTasksCore

@Suite struct WorktreeDamageTests {
    @Test func kind() {
        #expect(WorktreeDamage.of([]) == nil)
        #expect(WorktreeDamage.of([(false, true)]) == .folderGone)
        #expect(WorktreeDamage.of([(false, false), (false, true)]) == .folderGone)
        #expect(WorktreeDamage.of([(true, false)]) == .mainGone)
        #expect(WorktreeDamage.of([(true, true)]) == nil)
        #expect(WorktreeDamage.of([(true, false), (true, true)]) == nil)
        #expect(WorktreeDamage.of([(true, false), (false, false)]) == nil)
    }

    @Test func onlyWhatGitCannotTellIsPutUpWith() {
        var f = WorktreeCleanup.Facts(uniqueKeysWithValues: WorktreeCleanup.Protection.allCases.map { ($0, false) })
        for p in WorktreeDamage.unanswerable { f[p] = nil }
        func blocks(_ f: WorktreeCleanup.Facts) -> [WorktreeCleanup.Block] { WorktreeDamage.blocks(.init(members: [.init(path: "/w", facts: f)], activity: nil)) }
        #expect(blocks(f).isEmpty)
        for p in WorktreeCleanup.Protection.allCases {
            var known = f
            known[p] = true
            #expect(blocks(known) == [.init(protection: p, known: true)])
        }
        f[.terminal] = nil
        #expect(blocks(f) == [.init(protection: .terminal, known: false)])
    }

    @Test func adviceIsStrict() {
        #expect(WorktreeDamage.advice("{\"delete\": true, \"why\": \"тест\"}") == .init(delete: true, why: "тест"))
        #expect(WorktreeDamage.advice("```json\n{\"delete\": false, \"why\": \"код\"}\n```")?.delete == false)
        for bad in ["", "да", "{}", "{\"delete\": \"true\", \"why\": \"x\"}", "} {", "{\"why\": \"x\"}"] { #expect(WorktreeDamage.advice(bad) == nil) }
    }
}
