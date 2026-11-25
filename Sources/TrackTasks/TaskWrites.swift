import Foundation
import TrackTasksCore

/// Every write of task files by the app goes through here: one after another, in the order asked, never on the main
/// thread, because the folder lock shared with `tt` may have to be waited for.
@MainActor
enum TaskWrites {
    nonisolated private static let queue = DispatchQueue(label: "TrackTasks.taskWrites", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: Result(catching: work)) }
        }
    }

    /// On quit: lets writes already asked for finish, but doesn't hang on somebody else's lock.
    nonisolated static func flush(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
