import Foundation
import Testing
import TrackTasksCore
@testable import TrackTasks

/// Real containers with a stand-in for the agent. Needs a running Docker and an image that is already here (nothing is
/// downloaded): TRACKTASKS_DOCKER_IMAGE or node:22-alpine; otherwise the tests are marked as skipped.
enum TestDocker {
    static let image = ProcessInfo.processInfo.environment["TRACKTASKS_DOCKER_IMAGE"] ?? "node:22-alpine"
    static let engine: DockerEngine? = DockerEngine.find().flatMap { $0.isUp && $0.hasImage(image) ? $0 : nil }
}

@Suite("Docker: настоящий контейнер", .serialized, .enabled(if: TestDocker.engine != nil, "нет Docker или образа"))
struct DockerRunTests {
    let engine: DockerEngine
    let dir: URL, main: URL, wt: Worktrees.Info, base: String, seal: URL
    let instance = "test-" + UUID().uuidString

    init() throws {
        engine = try #require(TestDocker.engine)
        // Under the home folder: Docker Desktop shares it. The space is on purpose.
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tt docker \(UUID().uuidString)")
        main = dir.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try "old\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for a in [["init", "-q"], ["config", "user.name", "t"], ["config", "user.email", "t@t"], ["add", "-A"], ["commit", "-qm", "c"]] {
            #expect(Worktrees.git(a, in: main).ok)
        }
        let path = dir.appendingPathComponent("wt")
        #expect(Worktrees.git(WorktreeGit.add(branch: "b", path: path.path, base: "HEAD"), in: main).ok)
        wt = Worktrees.Info(path: path, main: main, branch: "b")
        base = Worktrees.git(["rev-parse", "HEAD"], in: main).out.trimmingCharacters(in: .whitespacesAndNewlines)
        seal = dir.appendingPathComponent("seal")
        try ContainerSpec.gitLink.write(to: seal, atomically: true, encoding: .utf8)
        try "секрет".write(to: main.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    private func make(_ sh: String) -> DockerRun {
        DockerRun(engine, ContainerSpec(image: TestDocker.image, worktree: wt.path, gitSeal: seal,
                                        command: ["sh", "-c", sh], instance: instance, job: "j"))
    }

    private func done() { try? FileManager.default.removeItem(at: dir) }

    @Test func nothingOutsideWorktree() throws {
        defer { done() }
        let secret = main.appendingPathComponent("secret.txt").path
        try FileManager.default.createSymbolicLink(atPath: wt.path.appendingPathComponent("link").path, withDestinationPath: secret)
        let sealed = try #require(WorktreeSeal.read(wt.path))
        let o = make("""
        cat a.txt
        cat '\(secret)' link ../main/secret.txt '\(main.path)/.git/config' && echo LEAK
        ls /var/run/docker.sock /run/docker.sock /Users /host_mnt /run/host_mark >/dev/null && echo LEAK
        [ -e /Users ] && echo LEAK
        [ -S /var/run/docker.sock ] && echo LEAK
        [ "$(id -u)" = 0 ] && echo LEAK
        env | grep -i -e CLAUDE -e SSH_ && echo LEAK
        echo evil > .git; rm -rf .git; mv .git g; ln -sf /etc .git
        touch /etc/x && echo LEAK
        echo END
        """).run(timeout: 60)
        #expect(o.result.out.hasPrefix("old\n") && o.result.out.hasSuffix("END\n"), "\(o.result)")
        #expect(!o.result.out.contains("LEAK"), "\(o.result.out)")
        #expect(!o.result.out.contains("секрет"))
        #expect(WorktreeSeal.problem(wt.path, sealed: sealed) == nil)
        #expect(o.leftover == nil && !o.stopped)
        #expect(engine.containers(instance: instance) == [])
    }

    @Test func resultIsInOrdinaryDiff() throws {
        defer { done() }
        let o = make("echo new > a.txt; echo 1 > b.txt").run(timeout: 60)
        #expect(o.result.ok, "\(o.result)")
        let d = Worktrees.git(["diff", "--", "a.txt"], in: wt.path)
        #expect(d.out.contains("+new"))
        #expect(Worktrees.commitAll(wt, message: "m").ok)
        #expect(Worktrees.diffStat(wt, base: base).contains("2 files changed"))
    }

    /// Only with git in the image.
    @Test func gitWorksInside() throws {
        defer { done() }
        let o = make("command -v git >/dev/null || { echo NOGIT; exit; }; git status --short; echo new > a.txt; git diff").run(timeout: 60)
        guard o.result.out != "NOGIT\n" else { return }
        #expect(o.result.out.hasPrefix("diff --git") && o.result.out.contains("+new"), "\(o.result)")
        #expect(!o.result.err.contains("no base git snapshot"))
    }

    @Test func stdinReachesCommand() {
        defer { done() }
        let o = make("read x; echo got $x").run(timeout: 60, input: "line\n")
        #expect(o.result.out == "got line\n", "\(o.result)")
    }

    @Test(arguments: [0, 100, 300, 2500]) func stopRemovesContainer(ms: Int) async throws {
        defer { done() }
        let r = make("sleep 300 & sleep 300")
        async let o = Task.detached { r.run(timeout: 120) }.value
        try await Task.sleep(for: .milliseconds(ms))
        let t = Date()
        await Task.detached { _ = r.stop() }.value
        let out = await o
        #expect(out.stopped && out.leftover == nil && !out.result.ok)
        #expect(Date().timeIntervalSince(t) < 30)
        #expect(engine.containers(instance: instance) == [])
    }

    @Test func timeoutRemovesContainer() {
        defer { done() }
        let o = make("sleep 300").run(timeout: 2)
        #expect(!o.result.ok && !o.stopped && o.leftover == nil)
        #expect(engine.containers(instance: instance) == [])
    }

    @Test func cleanupTouchesOnlyOwnLeftovers() throws {
        defer { done() }
        let mine = make("sleep 300"), live = make("sleep 300")
        for r in [mine, live] { #expect(engine.run(try r.spec.createArgs()).ok) }
        var foreign = ContainerSpec(image: TestDocker.image, worktree: wt.path, gitSeal: seal, command: ["true"], instance: instance + "x", job: "j")
        foreign.name += "-foreign"
        #expect(engine.run(try foreign.createArgs()).ok)
        #expect(engine.cleanup(instance: instance, keep: [live.spec.name]) == [])
        #expect(engine.containers(instance: instance) == [live.spec.name])
        #expect(engine.containers(instance: instance + "x") == [foreign.name])
        for n in [live.spec.name, foreign.name] { #expect(engine.remove(n) == nil) }
    }

    @Test func daemonFailureIsReported() {
        defer { done() }
        let broken = DockerEngine(cli: "/usr/bin/false")
        let o = DockerRun(broken, make("true").spec).run(timeout: 5)
        #expect(!o.result.ok && o.leftover != nil)
        #expect(!broken.cleanup(instance: instance, keep: []).isEmpty)
    }
}

/// A stand-in for the docker CLI: runs without a daemon.
@Suite("Docker: остановка без демона") struct DockerStopTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-docker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The container exists while the file `c` does. `create` waits for the file `go`.
    private func engine(rm: String = "rm -f c") throws -> DockerEngine {
        let cli = dir.appendingPathComponent("docker")
        try """
        #!/bin/sh
        cd '\(dir.path)' || exit 1
        echo "$1" >> calls
        case "$1" in
        create) touch creating; while [ ! -e go ]; do sleep 0.02; done; while [ $# -gt 0 ]; do [ "$1" = --name ] && echo "$2" > c; shift; done ;;
        start) exit 0 ;;
        rm) \(rm) ;;
        ps) [ -e down ] && exit 1; cat c 2>/dev/null; exit 0 ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return DockerEngine(cli: cli.path)
    }

    private func spec() -> ContainerSpec {
        ContainerSpec(image: "img", worktree: dir, gitSeal: dir.appendingPathComponent("seal"), command: ["true"], instance: "i", job: "j")
    }
    private func has(_ n: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) }
    private func touch(_ n: String) throws { try Data().write(to: dir.appendingPathComponent(n)) }
    private func calls() throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// `stop` finds nothing to remove yet, then `create` succeeds: nothing is started, the container is removed.
    @Test func stopBetweenCreateAndStart() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = DockerRun(try engine(), spec())
        let run = Task.detached { r.run(timeout: 20) }
        let limit = Date().addingTimeInterval(10)
        while !has("creating"), Date() < limit { try await Task.sleep(for: .milliseconds(20)) }
        #expect(r.stop() == nil)
        try touch("go")
        let o = await run.value
        #expect(o.stopped && !o.result.ok && o.leftover == nil)
        #expect(try !calls().contains("start"))
        #expect(try calls().suffix(2) == ["rm", "ps"])
        #expect(!has("c"))
    }

    @Test func stopBeforeRun() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = DockerRun(try engine(), spec())
        r.stop()
        let o = r.run(timeout: 5)
        #expect(o.stopped && !o.result.ok)
        #expect(try !calls().contains("create"))
    }

    /// Whatever text `rm` fails with, only the list of containers decides.
    @Test func removalIsCheckedNotParsed() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch("go")
        let o = DockerRun(try engine(rm: "echo 'нет такого' >&2; rm -f c; exit 1"), spec()).run(timeout: 5)
        #expect(o.leftover == nil && o.result.ok)
        try touch("down")
        #expect(DockerRun(try engine(), spec()).run(timeout: 5).leftover != nil)
    }
}
