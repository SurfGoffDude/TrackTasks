import Foundation
import Testing
@testable import TrackTasksCore

@Suite("PushPolicy")
struct PushPolicyTests {
    @Test func briefHasNoProjectOrTask() {
        for e in PushEvent.allCases {
            let m = PushPolicy.message(e, detail: .brief, project: "СекретныйПроект", task: "Правка auth.swift")
            #expect(!m.title.contains("СекретныйПроект") && !m.body.contains("СекретныйПроект"))
            #expect(!m.title.contains("auth") && !m.body.contains("auth"))
        }
        let full = PushPolicy.message(.done, detail: .full, project: "P", task: "T")
        #expect(full.body == "P: T")
    }

    @Test func quietHours() {
        #expect(PushPolicy.isQuiet(minute: 23 * 60, start: 22 * 60, end: 8 * 60))
        #expect(PushPolicy.isQuiet(minute: 7 * 60, start: 22 * 60, end: 8 * 60))
        #expect(!PushPolicy.isQuiet(minute: 12 * 60, start: 22 * 60, end: 8 * 60))
        #expect(PushPolicy.isQuiet(minute: 13 * 60, start: 12 * 60, end: 14 * 60))
        #expect(!PushPolicy.isQuiet(minute: 100, start: 5, end: 5))
    }

    @Test func offByDefaultSendsNothing() {
        #expect(!PushPolicy.shouldSend(enabled: false, quietEnabled: false, minute: 0, start: 0, end: 0))
        #expect(!PushPolicy.shouldSend(enabled: true, quietEnabled: true, minute: 60, start: 22 * 60, end: 8 * 60))
        #expect(PushPolicy.shouldSend(enabled: true, quietEnabled: true, minute: 12 * 60, start: 22 * 60, end: 8 * 60))
    }

    @Test func httpOnlyForLocalhost() {
        let m = PushMessage(title: "t", body: "b")
        func ok(_ s: String) -> Bool { PushRequestBuilder.ntfy(server: s, topic: "a", token: "tk", message: m) != nil }
        for s in ["", "https://push.example.com", "http://localhost:8080/", "http://127.0.0.1:80", "http://[::1]:8080"] {
            #expect(ok(s) && PushRequestBuilder.serverAllowed(s), "\(s)")
        }
        for s in ["http://ntfy.sh", "http://localhost.evil.com", "http://localhost@evil.com", "ftp://localhost", "ntfy.sh"] {
            #expect(!ok(s) && !PushRequestBuilder.serverAllowed(s), "\(s)")
        }
    }

    @Test func requests() throws {
        let m = PushMessage(title: "Готово", body: "TrackTasks")
        let n = try #require(PushRequestBuilder.ntfy(server: "", topic: "abc_1", token: "tk", message: m))
        #expect(n.url?.absoluteString == "https://ntfy.sh/abc_1")
        #expect(n.value(forHTTPHeaderField: "Authorization") == "Bearer tk")
        #expect(PushRequestBuilder.ntfy(server: "", topic: "a/b", token: nil, message: m) == nil)
        let p = try #require(PushRequestBuilder.pushover(appToken: "a", userKey: "u", message: m))
        #expect(String(decoding: p.httpBody ?? Data(), as: UTF8.self).contains("user=u"))
        #expect(PushRequestBuilder.pushover(appToken: "", userKey: "u", message: m) == nil)
    }

    @Test func fullTextPerWait() {
        let link = AppLink.openTask(UUID())
        let want: [(PushWait, String)] = [(.permission, "нужно разрешение"), (.plan, "план ждёт одобрения"),
                                          (.question, "агент задал вопрос"), (.redCheck, "проверка не прошла")]
        for (w, text) in want {
            let m = PushPolicy.message(.permission, detail: .full, project: "P", task: "T", wait: w, link: link)
            #expect(m.body == "P: T — " + text)
            #expect(m.link == link.url)
        }
        let red = PushPolicy.message(.done, detail: .full, project: "P", task: "T", verifyFailed: true)
        #expect(red.body == "P: T — проверка не прошла")
    }

    @Test func briefHasNoWaitNoLink() {
        for e in PushEvent.allCases {
            for w in PushWait.allCases {
                let m = PushPolicy.message(e, detail: .brief, project: "Секрет", task: "auth.swift", verifyFailed: true, wait: w, link: .openTask(UUID()))
                #expect(m.body == "TrackTasks" && m.link == nil)
                #expect(!m.title.contains("Секрет") && !m.title.contains("auth"))
            }
        }
    }

    @Test func linkInRequests() throws {
        let id = UUID()
        let m = PushMessage(title: "t", body: "b", link: AppLink.openTask(id).url)
        let n = try #require(PushRequestBuilder.ntfy(server: "", topic: "abc", token: nil, message: m))
        #expect(n.value(forHTTPHeaderField: "Click") == "tracktasks://task/\(id.uuidString)")
        let p = try #require(PushRequestBuilder.pushover(appToken: "a", userKey: "u", message: m))
        #expect(String(decoding: p.httpBody ?? Data(), as: UTF8.self).contains("url=tracktasks%3A%2F%2Ftask%2F"))
        let plain = try #require(PushRequestBuilder.ntfy(server: "", topic: "abc", token: nil, message: PushMessage(title: "t", body: "b")))
        #expect(plain.value(forHTTPHeaderField: "Click") == nil)
    }

    @Test func linkParsing() {
        let id = UUID()
        #expect(AppLink.parse(URL(string: AppLink.openTask(id).url)!) == .openTask(id))
        // Неизвестные адреса, действия и лишние части — ничего не делают.
        for s in ["tracktasks://task/not-a-uuid", "tracktasks://task/", "tracktasks://task", "tracktasks://approve/\(id.uuidString)",
                  "tracktasks://task/\(id.uuidString)/merge", "tracktasks://task/\(id.uuidString)?action=merge",
                  "tracktasks://task/\(id.uuidString)#run", "tracktasks://merge?id=\(id.uuidString)",
                  "tracktasks://evil@task/\(id.uuidString)", "https://task/\(id.uuidString)", "tracktasks://run/\(id.uuidString)"] {
            #expect(AppLink.parse(URL(string: s)!) == nil, "\(s)")
        }
    }
}
