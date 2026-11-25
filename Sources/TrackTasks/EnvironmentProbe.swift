import Foundation
import TrackTasksCore

/// The real Mac. Output may carry an email: it is neither logged nor kept.
struct EnvironmentProbe: CheckEnvironment {
    private static let timeout: TimeInterval = 20

    func prepare() { _ = ClaudeLocator.resolve() }

    func find(_ tool: CheckTool) -> String? {
        switch tool {
        case .git: "/usr/bin/git"
        case .claude: ClaudeLocator.known()
        case .codex: CodexLocator.resolve()
        case .gh: GitHubCLI.locate()
        }
    }

    func folder(_ url: URL) -> CheckFolder {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &dir) else { return .missing }
        guard dir.boolValue else { return .notFolder }
        return fm.isReadableFile(atPath: url.path) && fm.isWritableFile(atPath: url.path) ? .ready : .denied
    }

    func developerTools() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let r = TimedProcess.run(p, timeout: 5)
        let dir = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        // The selected folder may have been deleted.
        return r.ok && !dir.isEmpty && FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/git")
    }

    func run(_ tool: CheckTool, _ args: [String]) -> CheckOutput {
        guard let path = find(tool) else { return CheckOutput(ok: false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["PATH"] = [(path as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        p.environment = env
        return Self.output { TimedProcess.run(p, timeout: Self.timeout, killTree: true) }
    }

    func ghLogin() -> CheckOutput {
        Self.output { GitHubCLI.loginCheck("github.com", in: FileManager.default.temporaryDirectory) }
    }

    func codex() async -> CheckCodex { await Self.askCodex() }

    /// `TimedProcess` stops a silent program after its timeout, which also is the only way to wait that long.
    private static func output(_ body: () -> Worktrees.Result) -> CheckOutput {
        let start = ContinuousClock.now
        let r = body()
        return CheckOutput(ok: r.ok, out: r.out, err: r.err, timedOut: !r.ok && ContinuousClock.now - start >= .seconds(timeout))
    }

    @MainActor private static func askCodex() async -> CheckCodex {
        let p = CodexProcess()
        return await withCheckedContinuation { c in
            p.onExit = { r in
                c.resume(returning: CheckCodex(r))
            }
            do { try p.start(nil, executable: nil) } catch {
                p.onExit = nil
                c.resume(returning: .problem(error.localizedDescription))
            }
        }
    }
}
