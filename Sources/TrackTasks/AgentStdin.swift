import Foundation

/// JSON lines to an agent. Writes off the main thread: a hung agent must not freeze the app when the pipe is full.
final class AgentStdin: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agent.stdin")
    private let handle: FileHandle
    init(_ h: FileHandle) {
        handle = h
        _ = fcntl(h.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        queue.async { [handle] in try? handle.write(contentsOf: d + Data([0x0A])) }
    }
    func close() { queue.async { [handle] in try? handle.close() } }
}
