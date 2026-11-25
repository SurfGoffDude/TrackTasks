import Foundation
import Testing
@testable import TrackTasksCore

/// The server's script itself, under /bin/sh (and dash when there is one), without ssh.
@Suite(.serialized) struct RemoteRunnerTests {
    let root: URL, script: URL
    init() throws {
        root = URL(fileURLWithPath: "/tmp/tt-runner-\(UUID().uuidString.prefix(8))")
        script = root.appendingPathComponent("bin/\(RemoteRunner.fileName)")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RemoteRunner.script.write(to: script, atomically: true, encoding: .utf8)
    }

    private func sh(_ args: [String], input: String = "", shell: String = "/bin/sh") throws -> (Int32, String) {
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        try p.run()
        try inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try inp.fileHandleForWriting.close()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, s)
    }
    private func op(_ words: String..., input: String = "") throws -> (Int32, String) { try sh([script.path] + words, input: input) }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/zsh"]) func syntax(shell: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        #expect(try sh(["-n", script.path], shell: shell).0 == 0)
    }

    @Test func idsAreChecked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep")
        try "x".write(to: keep, atomically: true, encoding: .utf8)
        for bad in ["..", "../keep", "", "a/b", "*"] {
            #expect(try op("rmrun", bad, "p").0 == 91)
            #expect(try op("rmwork", bad, "p").0 == 91)
            #expect(try op("size", bad, "vars").0 == 91)
        }
        #expect(try op("size", "r", "../../keep").0 == 91)
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func uploadGoesOnAndIsChecked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "привет, мир", d = Data(text.utf8), sha = RemoteRun.sha256(d)
        #expect(try op("size", "r", "vars").1 == "0\n")
        #expect(try op("append", "r", "vars", input: "привет").0 == 0)
        #expect(try op("size", "r", "vars").1 == "12\n")
        #expect(try op("seal", "r", "vars", String(d.count), sha).0 == RemoteRunner.badUpload)
        _ = try op("append", "r", "vars", input: text)
        #expect(try op("seal", "r", "vars", String(d.count), sha).0 == 0)
        #expect(try op("size", "r", "vars").1 == "sealed\n")
    }

    @Test func messageNumberIsTakenOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try op("size", "r", "vars")
        #expect(try op("put", "r", "1", "2", input: "a\n").0 == 0)
        #expect(try op("put", "r", "1", "2", input: "a\n").0 == 0)
        #expect(try op("put", "r", "1", "2", input: "b\n").0 == RemoteRunner.taken)
        // Cut on the way.
        #expect(try op("put", "r", "2", "9", input: "b\n").0 == RemoteRunner.badUpload)
        #expect(RemoteState(try op("state", "r").1).inputs == 1)
    }

    @Test func stopBeforeStart() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try op("size", "r", "vars")
        #expect(try op("stop", "r").0 == 0)
        #expect(try op("start", "r", "w", "p", "coding", "abc", "claude").0 == 0)
        let d = RemoteState(try op("state", "r").1).done
        #expect(d?.cancelled == true && d?.claudeStarted == false)
        #expect(try op("state", "none").0 == RemoteRunner.noRun)
    }

    @Test func stateNeedsTheEnd() {
        try? FileManager.default.removeItem(at: root)
        #expect(RemoteState("lock=1\nexit=0\nbundle=3 abc").done == nil)
        let s = RemoteState("lock=1\nin=2\nanswered=\"request_id\":\"r1\"\nexit=1\ncancelled=0\nclaude=1\nout=5\nbundle=7 \(String(repeating: "a", count: 64))\ntask=none\nerror=a=b\nend=1")
        #expect(s.answered == ["r1"] && s.inputs == 2 && s.started)
        #expect(s.done?.bundle?.size == 7 && s.done?.task == nil && s.done?.error == "a=b" && s.done?.out == 5)
    }
}
