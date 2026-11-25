import Foundation
import Testing
@testable import TrackTasksCore

struct SSHCommandTests {
    @Test func hostKeyIsAlwaysChecked() throws {
        let a = try #require(SSHCommand.args(RemoteServer(host: "h", user: "u", port: 2222), command: "c", extra: ["-F", "/x"]))
        for o in ["StrictHostKeyChecking=yes", "BatchMode=yes", "NoHostAuthenticationForLocalhost=no", "VerifyHostKeyDNS=no",
                  "UpdateHostKeys=no", "ForwardAgent=no", "ControlPath=none"] { #expect(a.contains(o)) }
        // Before anything a test or a config may add.
        #expect(a.firstIndex(of: "StrictHostKeyChecking=yes")! < a.firstIndex(of: "-F")!)
        #expect(a.suffix(3) == ["--", "h", "c"])
        #expect(SSHCommand.args(RemoteServer(host: "-oX"), command: "c") == nil)
    }

    @Test func commandWordsAreSafe() {
        let s = RemoteServer(host: "h")
        #expect(SSHCommand.runner(s, ["state", "a-1"]) == "exec /bin/sh .tracktasks/bin/\(RemoteRunner.fileName) state a-1")
        for w in ["a b", "a;b", "$(x)", "a'b", "", "a\nb", "a|b", "a\n"] { #expect(SSHCommand.runner(s, ["state", w]) == nil) }
    }

    @Test(arguments: ["", "a", "it's", "$(touch x)", "`x`", "a\nb", "'; rm -rf /; '", "\\", "кириллица"]) func quoting(_ s: String) throws {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + SSHCommand.quote(s)]
        p.standardOutput = out
        try p.run()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == s)
    }

    @Test func failures() {
        #expect(SSHCommand.failure(status: 1, stderr: "Host key verification failed.") == nil)
        #expect(SSHCommand.failure(status: 255, stderr: "No ED25519 host key is known for h and you have requested strict checking.\nHost key verification failed.") == .unknownHostKey)
        #expect(SSHCommand.failure(status: 255, stderr: "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.") == .changedHostKey)
        #expect(SSHCommand.failure(status: 255, stderr: "u@h: Permission denied (publickey).") == .auth)
        #expect(SSHCommand.failure(status: 255, stderr: "ssh: connect to host h port 22: Connection refused") == .noConnection)
    }
}
