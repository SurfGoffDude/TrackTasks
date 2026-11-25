import Darwin
import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct ACPAccessTests {
    let root: URL, cwd: URL, tasks: URL, out: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("tt-acp-\(UUID().uuidString)")
        cwd = root.appendingPathComponent("wt")
        tasks = root.appendingPathComponent("main/tasks")
        out = root.appendingPathComponent("out")
        for d in [cwd.appendingPathComponent("tasks"), tasks, out] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try "секрет".write(to: out.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try "1\n2\n3\n4".write(to: cwd.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: cwd.appendingPathComponent("link.txt"), withDestinationURL: out.appendingPathComponent("s.txt"))
        try fm.createSymbolicLink(at: cwd.appendingPathComponent("dir"), withDestinationURL: out)
        try fm.createSymbolicLink(at: cwd.appendingPathComponent("dangling"), withDestinationURL: out.appendingPathComponent("no"))
        try fm.createSymbolicLink(at: cwd.appendingPathComponent("inner"), withDestinationURL: cwd.appendingPathComponent("a.txt"))
    }

    private func a(_ access: AgentAccess = .coding) -> ACPAccess { ACPAccess(access: access, cwd: cwd, addDirs: [tasks]) }
    private func p(_ s: String) -> String { cwd.path + "/" + s }

    @Test func outsideIsRefused() throws {
        let bad = [out.path + "/s.txt", p("link.txt"), p("dir/s.txt"), p("../out/s.txt"), p("dangling"), p("dir/new.txt"), "a.txt", "/etc/hosts",
                   cwd.path, cwd.path + "2/x", p("a\0b")]
        for path in bad {
            #expect(throws: ACPAccess.Refusal.outside, "\(path)") { try a().read(path) }
            #expect(throws: ACPAccess.Refusal.outside, "\(path)") { try a().write(path, "x") }
        }
        #expect(try String(contentsOf: out.appendingPathComponent("s.txt"), encoding: .utf8) == "секрет")
        #expect(try fm.contentsOfDirectory(atPath: out.path) == ["s.txt"])
        #expect(a().folder(p("dir")) == nil && a().folder(out.path) == nil && a().folder(p("a.txt")) == nil && a().folder(p("no")) == nil)
        #expect(a().folder(p("tasks")) != nil && a().folder(cwd.path) != nil)
    }

    @Test func readsLines() throws {
        #expect(try a().read(p("a.txt")) == "1\n2\n3\n4")
        #expect(try a().read(p("inner")) == "1\n2\n3\n4")
        #expect(try a().read(p("a.txt"), line: 2, limit: 2) == "2\n3")
        #expect(try a().read(p("a.txt"), line: 0, limit: 1) == "1")
        #expect(try a().read(p("a.txt"), line: 9) == "")
        #expect(throws: ACPAccess.Refusal.notFound) { try a().read(p("no.txt")) }
        #expect(throws: ACPAccess.Refusal.notAFile) { try a().read(p("tasks")) }
        #expect(throws: ACPAccess.Refusal.outside) { try a(.answer).read(p("a.txt")) }
    }

    @Test func writes() throws {
        try a().write(p("new/deep/x.txt"), "привет")
        #expect(try a().read(p("new/deep/x.txt")) == "привет")
        chmod(p("a.txt"), 0o755)
        try a().write(p("a.txt"), "z")
        var st = stat()
        #expect(stat(p("a.txt"), &st) == 0 && st.st_mode & 0o777 == 0o755)
        try a().write(tasks.path + "/t.md", "x")
        // Through a link inside: its target is replaced, the link stays.
        try a().write(p("inner"), "q")
        #expect(try a().read(p("a.txt")) == "q" && lstat(p("inner"), &st) == 0 && st.st_mode & S_IFMT == S_IFLNK)
        #expect(throws: ACPAccess.Refusal.notAFile) { try a().write(p("tasks"), "x") }
        #expect(try fm.contentsOfDirectory(atPath: cwd.path).allSatisfy { !$0.hasPrefix(".tracktasks") })
    }

    @Test func protectedFiles() throws {
        for path in [".git", ".git/config", ".GIT/hooks/x", "sub/.claude/settings.json", ".codex/x", ".agents/x"] {
            #expect(throws: ACPAccess.Refusal.protected, "\(path)") { try a().write(p(path), "x") }
        }
        for path in ["a.txt", "src/tasks/x", "sub/about.md", "tasks"] {
            #expect(throws: ACPAccess.Refusal.protected, "\(path)") { try a(.planning).write(p(path), "x") }
        }
        for path in ["tasks/t.md", "about.md", "spectrack.md"] { try a(.planning).write(p(path), "x") }
        try a(.planning).write(tasks.path + "/t.md", "x")
    }

    @Test func specialFiles() throws {
        #expect(mkfifo(p("fifo"), 0o600) == 0)
        #expect(throws: ACPAccess.Refusal.notAFile) { try a().read(p("fifo")) }
        #expect(throws: ACPAccess.Refusal.notAFile) { try a().write(p("fifo"), "x") }
        #expect(fm.createFile(atPath: p("big"), contents: nil) && truncate(p("big"), off_t(ACPAccess.maxSize + 1)) == 0)
        #expect(throws: ACPAccess.Refusal.tooBig) { try a().read(p("big")) }
        try Data([0xFF, 0xFE]).write(to: URL(fileURLWithPath: p("bin")))
        #expect(throws: ACPAccess.Refusal.notText) { try a().read(p("bin")) }
    }
}
