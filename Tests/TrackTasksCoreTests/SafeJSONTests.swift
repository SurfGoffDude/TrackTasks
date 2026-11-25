import XCTest
@testable import TrackTasksCore

final class SafeJSONTests: XCTestCase {
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("safejson-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testMissing() {
        let u = tmp().appendingPathComponent("a.json")
        guard case .missing = SafeJSON.load([Int].self, from: u) else { return XCTFail() }
    }

    func testCorruptKeepsCopy() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try Data("{broken".utf8).write(to: u)
        guard case .corrupt(let b, _) = SafeJSON.load([Int].self, from: u), let backup = b else { return XCTFail() }
        XCTAssertTrue(backup.lastPathComponent.contains(".corrupt-"))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{broken")
    }

    func testFailedMoveBlocksSave() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try Data("{broken".utf8).write(to: u)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        if getuid() == 0 { throw XCTSkip("root ignores permissions") }
        guard case .corrupt(let b, _) = SafeJSON.load([Int].self, from: u) else { return XCTFail() }
        XCTAssertNil(b)
        XCTAssertTrue(SafeJSON.isBlocked(u))
        XCTAssertThrowsError(try SafeJSON.save(Data("[1]".utf8), to: u))
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{broken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bak.json").path))
    }

    func testUnreadableNotMovedAndBlocked() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try Data("[1]".utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: u.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path) }
        if getuid() == 0 { throw XCTSkip("root ignores permissions") }
        guard case .unreadable = SafeJSON.load([Int].self, from: u) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.json"])
        XCTAssertThrowsError(try SafeJSON.save(Data("[2]".utf8), to: u))
    }

    func testTwoCorruptionsSameSecondKeepBoth() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json"); let now = Date()
        var urls = Set<URL>()
        for _ in 0..<2 {
            try Data("{broken".utf8).write(to: u)
            guard case .corrupt(let b, _) = SafeJSON.load([Int].self, from: u, now: now), let backup = b else { return XCTFail() }
            urls.insert(backup)
        }
        XCTAssertEqual(urls.count, 2)
    }

    func testCorruptThenSaveDoesNotPoisonBak() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try Data("{broken".utf8).write(to: u)
        _ = SafeJSON.load([Int].self, from: u)
        try SafeJSON.save(Data("[1]".utf8), to: u)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bak.json").path))
    }

    func testSaveSameContentKeepsOlderBak() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try SafeJSON.save(Data("[1]".utf8), to: u)
        try SafeJSON.save(Data("[2]".utf8), to: u)
        try SafeJSON.save(Data("[2]".utf8), to: u)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.bak.json"), encoding: .utf8), "[1]")
    }

    func testSaveWriteFailureThrows() throws {
        if getuid() == 0 { throw XCTSkip("root ignores permissions") }
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try SafeJSON.save(Data("[1]".utf8), to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try SafeJSON.save(Data("[2]".utf8), to: u))
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "[1]")
    }

    func testSaveRotatesBak() throws {
        let dir = tmp(); let u = dir.appendingPathComponent("a.json")
        try SafeJSON.save(Data("[1]".utf8), to: u)
        try SafeJSON.save(Data("[2]".utf8), to: u)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "[2]")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.bak.json"), encoding: .utf8), "[1]")
        guard case .value(let v) = SafeJSON.load([Int].self, from: u) else { return XCTFail() }
        XCTAssertEqual(v, [2])
    }
}
