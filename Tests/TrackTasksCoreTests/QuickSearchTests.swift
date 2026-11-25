import XCTest
@testable import TrackTasksCore

final class QuickSearchTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ text: String = "", project: String = "p", kind: SearchEntry.Kind = .task,
                       status: TaskStatus? = .todo) -> SearchEntry {
        SearchEntry(id: id, kind: kind, projectID: project, projectName: project, title: title, text: text, status: status)
    }

    func testTypoFindsTask() {
        var ix = QuickSearchIndex()
        ix.replace(project: "p", with: [entry("1", "Контрольные точки сессии"), entry("2", "Архив задач")])
        XCTAssertEqual(ix.search("контрольные").first?.entry.id, "1")
        XCTAssertEqual(ix.search("контролные").first?.entry.id, "1")   // missing letter
        XCTAssertEqual(ix.search("архиф").first?.entry.id, "2")        // substitution
        XCTAssertEqual(ix.search("акрхив").first?.entry.id, "2")       // swap
        XCTAssertTrue(ix.search("баклажан").isEmpty)
    }

    func testPrefixAndAllWords() {
        var ix = QuickSearchIndex()
        ix.replace(project: "p", with: [entry("1", "Поиск сессий"), entry("2", "Поиск задач")])
        XCTAssertEqual(ix.search("поис").count, 2)
        XCTAssertEqual(ix.search("поиск сесс").map(\.entry.id), ["1"])
    }

    func testTitleBeatsTextAndDoneIsLower() {
        var ix = QuickSearchIndex()
        ix.replace(project: "p", with: [entry("body", "Другое", "про очередь"), entry("title", "Очередь"),
                                         entry("done", "Очередь", status: .done)])
        XCTAssertEqual(ix.search("очередь").map(\.entry.id), ["title", "done", "body"])
    }

    func testReplaceProjectRemovesOld() {
        var ix = QuickSearchIndex()
        ix.replace(project: "a", with: [entry("1", "Alpha", project: "a")])
        ix.replace(project: "b", with: [entry("2", "Alpha", project: "b")])
        ix.replace(project: "a", with: [entry("3", "Beta", project: "a")])
        XCTAssertEqual(ix.search("alpha").map(\.entry.id), ["2"])
        XCTAssertEqual(ix.search("beta").map(\.entry.id), ["3"])
        for i in 0..<400 { ix.replace(project: "a", with: [entry("x\(i)", "Gamma\(i)", project: "a")]) }
        XCTAssertEqual(ix.search("alpha").map(\.entry.id), ["2"])
        XCTAssertEqual(ix.search("gamma399").map(\.entry.id), ["x399"])
        XCTAssertEqual(ix.count, 2)
    }

    func testWithinOne() {
        func w(_ a: String, _ b: String) -> Bool { QuickSearchIndex.withinOne(a.unicodeScalars.map(\.value), b.unicodeScalars.map(\.value)[...]) }
        XCTAssertTrue(w("abcd", "abcd")); XCTAssertTrue(w("abcd", "abxd")); XCTAssertTrue(w("abcd", "abd"))
        XCTAssertTrue(w("abd", "abcd")); XCTAssertTrue(w("abcd", "bacd")); XCTAssertFalse(w("abcd", "axyd"))
        XCTAssertFalse(w("abcd", "ab"))
    }

    func testFastOn120Projects() {
        var ix = QuickSearchIndex()
        let words = (0..<3000).map { "слово\($0)" }
        for p in 0..<120 {
            var es: [SearchEntry] = []
            for t in 0..<40 {
                let body = (0..<80).map { words[(p * 31 + t * 7 + $0 * 13) % words.count] }.joined(separator: " ")
                es.append(entry("\(p)-\(t)", "Задача \(p) номер \(t) \(words[(p + t) % words.count])", body, project: "proj\(p)"))
            }
            ix.replace(project: "proj\(p)", with: es)
        }
        // CPU time of this thread, not the clock: parallel builds must not fail the test. The search is pure computation.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for q in ["задача номер", "слово1234", "слово123x", "поиск по всему"] { _ = ix.search(q) }
        let per = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9 / 4
        XCTAssertLessThan(per, 0.1, "search took \(per)s")
    }
}
