import Foundation
import CoreServices

/// Recursive FSEvents watcher. The handler runs on a private background queue
/// with events coalesced over `latency` seconds.
public final class FileWatcher {
    public struct Event: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags

        public init(path: String, flags: FSEventStreamEventFlags) {
            self.path = path
            self.flags = flags
        }

        public var isDir: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 }
        public var mustRescan: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
        public var isCreateRemoveRename: Bool {
            let mask = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            return flags & FSEventStreamEventFlags(mask) != 0
        }
    }

    public typealias Handler = ([Event]) -> Void

    /// Owned by the stream (retained via the context, released by FSEvents), so callbacks never outlive it.
    private final class Box {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "TrackTasks.FileWatcher", qos: .utility)

    public init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping Handler) {
        guard !paths.isEmpty else { return }
        let box = Unmanaged.passRetained(Box(handler))
        var ctx = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in
                if let info { Unmanaged<Box>.fromOpaque(info).release() }
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, paths.count) { events.append(Event(path: paths[i], flags: flags[i])) }
            box.handler(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            box.release()
            return
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
