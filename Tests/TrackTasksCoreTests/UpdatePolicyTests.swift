import Foundation
import Testing
@testable import TrackTasksCore

struct UpdatePolicyTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private var source: UpdatePolicy.Source? { .init(feed: "https://example.com/appcast.xml", key: key) }
    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func versions() {
        #expect(UpdatePolicy.isNewer("1.10", than: "1.9"))
        #expect(UpdatePolicy.isNewer("2", than: "1.9.9"))
        #expect(UpdatePolicy.isNewer("1.0.1", than: "1.0"))
        // The same, lower and unreadable ones are refused.
        for v in ["1.0", "1.0.0", "1", "0.9", "0.99.99", "", "1.x", "1..1", "2-beta", "v2", "-2", "+2", "2 ", "٢", "99999999999999999999"] {
            #expect(!UpdatePolicy.isNewer(v, than: "1.0"), "\(v)")
        }
        #expect(!UpdatePolicy.isNewer("2.0", than: "?"))
    }

    @Test func sourceNeedsHTTPSAndARealKey() {
        #expect(source != nil)
        for feed in [nil, "", "http://example.com/a.xml", "file:///a.xml", "https://", "не адрес"] {
            #expect(UpdatePolicy.Source(feed: feed, key: key) == nil, "\(feed ?? "nil")")
        }
        for k in [nil, "", "***", Data(repeating: 1, count: 31).base64EncodedString()] {
            #expect(UpdatePolicy.Source(feed: "https://example.com/a.xml", key: k) == nil)
        }
    }

    @Test func availability() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let app = d.appendingPathComponent("TrackTasks.app")
        func state(_ s: UpdatePolicy.Source?, _ enabled: Bool, _ a: URL? = nil) -> UpdatePolicy.Availability {
            UpdatePolicy.availability(source: s, app: a ?? app, enabled: enabled, brewPrefixes: [d])
        }
        #expect(state(nil, true) == .noSource)
        #expect(state(source, true) == .ready)
        #expect(state(source, false) == .manualOnly)
        #expect(state(source, true, URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/TrackTasks.app")) == .translocated)
        #expect(!UpdatePolicy.Availability.homebrew.mayCheckByHand && UpdatePolicy.Availability.manualOnly.mayCheckByHand)
    }

    @Test func homebrewOwnsOnlyItsOwnCopy() throws {
        let d = try folder()
        defer { try? FileManager.default.removeItem(at: d) }
        let fm = FileManager.default
        let brewed = d.appendingPathComponent("Applications/TrackTasks.app"), byHand = d.appendingPathComponent("My/TrackTasks.app")
        let version = d.appendingPathComponent("brew/Caskroom/tracktasks/1.0")
        for u in [brewed, byHand, version] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let prefix = d.appendingPathComponent("brew")
        // The folder alone isn't enough.
        #expect(!UpdatePolicy.ownedByHomebrew(brewed, prefixes: [prefix]))
        let link = version.appendingPathComponent("TrackTasks.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: brewed)
        #expect(UpdatePolicy.ownedByHomebrew(brewed, prefixes: [d.appendingPathComponent("none"), prefix]))
        #expect(!UpdatePolicy.ownedByHomebrew(byHand, prefixes: [prefix]))
        #expect(UpdatePolicy.availability(source: source, app: brewed, enabled: true, brewPrefixes: [prefix]) == .homebrew)
        // The cask's app is gone.
        try fm.removeItem(at: brewed)
        #expect(!UpdatePolicy.ownedByHomebrew(brewed, prefixes: [prefix]))
    }
}
