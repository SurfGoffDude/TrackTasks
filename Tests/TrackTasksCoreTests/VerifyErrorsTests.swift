import Testing
@testable import TrackTasksCore

@Suite("VerifyErrors")
struct VerifyErrorsTests {
    let log = "Compiling A\n/x/A.swift:4:15: \u{1B}[1;31merror: \u{1B}[1;39minvalid redeclaration of 'A'\u{1B}[0;0m\n    | `- error: invalid redeclaration of 'A'\n/x/A.swift:4:15: error: invalid redeclaration of 'A'\nerror: Build failed\n"

    @Test func keepsLocatedErrorsOnce() {
        #expect(VerifyErrors.lines(log) == ["/x/A.swift:4:15: error: invalid redeclaration of 'A'"])
        #expect(VerifyErrors.lines("✘ Test a() failed\nok").count == 1)
        #expect(VerifyErrors.lines("всё хорошо").isEmpty)
    }

    @Test func tailKeepsErrorsFromTheBeginning() {
        let t = VerifyErrors.tail(log + String(repeating: "x", count: 5000), limit: 1000)
        #expect(t.hasPrefix("/x/A.swift:4:15: error: invalid"))
        #expect(t.count < 1200)
        #expect(VerifyErrors.tail("короткий", limit: 100) == "короткий")
    }
}
