import Foundation
import os

/// One place for logging and signposts. Subsystem "TrackTasks", categories store / git / queue / fs.
/// Everything is `.info`/`.debug`: nothing of it is written to disk in release builds.
/// Watch: `log stream --level info --predicate 'subsystem == "TrackTasks"'`, or Instruments → Logging (os_signpost).
public struct Trace: Sendable {
    public let logger: Logger
    public let signposter: OSSignposter

    public init(category: String) {
        logger = Logger(subsystem: Log.subsystem, category: category)
        signposter = OSSignposter(subsystem: Log.subsystem, category: category)
    }

    /// Interval around a synchronous block; `detail` (project, command…) goes into the interval message.
    @discardableResult
    public func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String = "",
                           _ body: () throws -> T) rethrows -> T {
        let state = begin(name, detail())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Manual interval for work that spans queues; pass the result to `end`.
    public func begin(_ name: StaticString, _ detail: String = "") -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(detail, privacy: .public)")
    }

    public func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// A child-process launch: signpost event + info log line.
    public func process(_ tool: String, project: String, command: String) {
        signposter.emitEvent("process", "\(tool, privacy: .public) \(project, privacy: .public): \(command, privacy: .public)")
        logger.info("run \(tool, privacy: .public) [\(project, privacy: .public)] \(command, privacy: .public)")
    }
}

public enum Log {
    public static let subsystem = "TrackTasks"
    public static let store = Trace(category: "store")
    public static let git = Trace(category: "git")
    public static let queue = Trace(category: "queue")
    public static let fs = Trace(category: "fs")
}
