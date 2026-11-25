import Foundation

/// Blocking work outside the shared thread pool. The pool is as wide as the number of cores: a caller that blocks in it
/// while waiting for another block of the same pool never wakes up once every thread is taken by such callers.
public enum OwnThread {
    public static func start(group: DispatchGroup? = nil, _ work: @escaping @Sendable () -> Void) {
        group?.enter()
        let t = Thread {
            work()
            group?.leave()
        }
        t.qualityOfService = .userInitiated
        t.start()
    }

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in start { c.resume(returning: work()) } }
    }
}
