import Testing
@testable import TrackTasksCore

@Suite struct HangSampleTests {
    private func sample(_ threads: String) -> String { "Process: x [1]\n\nCall graph:\n\(threads)\nTotal number in stack (recursive): 5\nBinary Images:\n junk\n" }

    @Test func keepsStacksDropsIdle() {
        let t = HangSample.trim(sample("""
            10 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 10 start  (in dyld) + 6652  [0x18b820d7c]
            +   10 ???  (in helper)  load address 0x100334000 + 0x748  [0x100334748]
            +     ! 10 stuck()  (in Tests) + 8  [0x18b8afc20]  T.swift:5
            10 Thread_2
            + 10 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x18b8efcc4]
            +   10 __workq_kernreturn  (in libsystem_kernel.dylib) + 8  [0x18b8b19ec]
        """))
        #expect(t == """
        10 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        10 start  (in dyld) + 6652
        10 ???  (in helper)
        10 stuck()  (in Tests) + 8  T.swift:5
        """)
    }

    @Test func deepStackKeepsInnermostAndLimit() {
        let deep = (0..<100).map { "    + 10 frame\($0)  (in A) + 1  [0x1]" }.joined(separator: "\n")
        let t = HangSample.trim(sample("    10 Thread_1\n" + deep), framesPerThread: 5)
        #expect(t.contains("frame99") && t.contains("frame95") && !t.contains("frame94"))
        let many = (0..<300).map { "    10 Thread_\($0)\n" + deep }.joined(separator: "\n")
        #expect(HangSample.trim(sample(many), limit: 2000).count < 2100)
    }

    @Test func notASample() {
        #expect(HangSample.trim("sample cannot examine process 1") == "sample cannot examine process 1")
        #expect(HangSample.trim("").isEmpty)
    }
}
