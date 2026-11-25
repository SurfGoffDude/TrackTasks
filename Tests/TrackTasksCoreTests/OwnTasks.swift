import Foundation

/// The public copy of the repository has no tasks/: tests over them are skipped there.
let hasOwnTasks: Bool = {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    return FileManager.default.fileExists(atPath: dir.appendingPathComponent("tasks").path)
}()
