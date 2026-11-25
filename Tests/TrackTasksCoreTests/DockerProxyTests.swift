import Foundation
import Testing
@testable import TrackTasksCore

@Suite struct DockerProxyTests {
    @Test func domains() {
        #expect(DockerProxy.parse("api.anthropic.com, .npmjs.org\nA.b") == ["api.anthropic.com", ".npmjs.org", "a.b"])
        #expect(DockerProxy.parse("") == [])
        for bad in ["localhost", "10.0.0.1", "https://a.com", "a.com:443", "*.a.com", ".", "a..b", "-a.com", "a.com/x"] {
            #expect(DockerProxy.parse(bad) == nil, "\(bad)")
        }
    }

    @Test(arguments: ["swift test", "swift build && swift test", "cd x && xcodebuild -scheme A", "CI=1 xcrun simctl list", "sh -c 'swift test'"])
    func needsMac(_ c: String) { #expect(ContainerVerify.needsMac(c)) }

    @Test(arguments: ["", "pnpm typecheck && pnpm test", "npm run swiftly", "podman ps", "make test"])
    func runsInContainer(_ c: String) { #expect(!ContainerVerify.needsMac(c)) }

    @Test func agentSeesOnlyTheProxy() throws {
        var s = ContainerSpec(image: "i", worktree: URL(fileURLWithPath: "/w"), gitSeal: URL(fileURLWithPath: "/s"), command: ["c"], instance: "i", job: "j", uid: 501, gid: 20)
        #expect(try !s.createArgs().contains { $0.hasPrefix("HTTPS_PROXY") })
        s.network = .named(DockerProxy.network(s.name))
        s.viaProxy = true
        let a = try s.createArgs()
        #expect(a[try #require(a.firstIndex(of: "--network")) + 1] == s.name + "-net")
        #expect(a.contains("HTTPS_PROXY=" + DockerProxy.url))
        let p = DockerProxy(image: "p", domains: ["a.b", "c.d"])
        #expect(p.networkArgs("n", instance: "i", job: "j").contains("--internal"))
        let c = p.createArgs("n", instance: "i", job: "j")
        #expect(c.contains("TT_ALLOW=a.b,c.d") && !c.contains("--mount") && !c.contains("-v"))
    }

    @Test func autopilotNeverMergesUnchecked() {
        var f = Autopilot.Facts()
        f.verify = "swift test"
        f.approvedVerify = f.verify
        f.verdict = .ok
        #expect(Autopilot.step(f) == .merge)
        f.needsMac = true
        guard case .park = Autopilot.step(f) else { Issue.record("not parked"); return }
    }
}
