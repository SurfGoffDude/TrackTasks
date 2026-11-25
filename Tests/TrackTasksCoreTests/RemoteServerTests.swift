import Foundation
import Testing
@testable import TrackTasksCore

struct RemoteServerTests {
    @Test func oldProfilesAreRead() throws {
        let old = #"{"custom":[{"id":"x","title":"x","agent":"claude","model":"opus"}],"defaultID":"x"}"#
        let p = try JSONDecoder().decode(AgentProfiles.self, from: Data(old.utf8))
        #expect(p.resolve("")?.id == "x" && p.custom[0].server == nil)
    }

    @Test func serverProfileIsNeverTheDefault() {
        var p = AgentProfiles()
        #expect(p.add(AgentProfile(id: "box", title: "box", agent: .ssh)) != nil)
        #expect(p.add(AgentProfile(id: "box", title: "box", agent: .ssh, server: RemoteServer(host: "-oProxyCommand=x"))) != nil)
        #expect(p.add(AgentProfile(id: "box", title: "box", agent: .ssh, server: RemoteServer(host: "box"))) == nil)
        p.defaultID = "box"
        #expect(p.resolve("") == nil)
        #expect(p.resolve("box")?.server?.host == "box")
    }

    @Test(arguments: ["", "-x", "a b", "a;b", "a\nb", "$(x)", "`x`"]) func badHost(_ h: String) {
        #expect(RemoteServer(host: h).problem != nil)
    }

    @Test func otherFields() {
        #expect(RemoteServer(host: "h").problem == nil)
        #expect(RemoteServer(host: "::1", user: "u", port: 22, folder: "/srv/tt", claude: "/opt/c").problem == nil)
        #expect(RemoteServer(host: "h", user: "-l").problem != nil)
        #expect(RemoteServer(host: "h", port: 70000).problem != nil)
        for f in ["", "/", "../x", "a b", "~/x", "a'b", "-x"] { #expect(RemoteServer(host: "h", folder: f).problem != nil) }
        for c in ["", "bin/claude", "~/claude", "a b"] { #expect(RemoteServer(host: "h", claude: c).problem != nil) }
    }

    @Test func paths() {
        func t(_ s: String) -> String { RemotePaths.translate(s, code: "/wt/a", main: "/m/app", remoteCode: "/r/code", remoteProject: "/r/project") }
        #expect(t("/wt/a/x.swift и /m/app/tasks/t.md") == "/r/code/x.swift и /r/project/tasks/t.md")
        #expect(t("/m/app2 /m/app-old /m/app.") == "/m/app2 /m/app-old /r/project.")
        #expect(t("файл tasks/t.md, src/tasks/t.md") == "файл /r/project/tasks/t.md, src/tasks/t.md")
        let plan = RemotePaths.translate("/m/app/tasks/t.md /m/app/about.md /m/app/src", code: "/m/app", main: "/m/app", remoteCode: "/r/code", remoteProject: "/r/project")
        #expect(plan == "/r/project/tasks/t.md /r/project/about.md /r/code/src")
    }
}
