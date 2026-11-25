import Foundation
import TrackTasksCore

let env = ProcessInfo.processInfo.environment
// Same settings as the app; `tt` works without it, then the defaults apply.
let domains = UserDefaultsDomains()
let root = env["TT_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? (SettingsMigration.value("rootPath", domains: domains) as? String) ?? "~/Projects"

let socket = env["TT_SOCKET"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? QueueSocket.defaultURL

let cli = CLI(
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    root: URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true),
    // TT_ROOT names the whole set of projects: folders added in the app do not belong to it.
    extras: env["TT_ROOT"].map { !$0.isEmpty } == true ? [] : SettingsMigration.value("extraFolders", domains: domains) as? [String] ?? [],
    isTTY: isatty(STDOUT_FILENO) == 1,
    stdinTTY: isatty(STDIN_FILENO) == 1,
    stdin: { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) },
    transport: { try QueueSocketClient(url: socket).send($0) },
    out: { fputs($0, stdout); fflush(stdout) },
    err: { fputs($0, stderr) },
    input: { FileHandle.standardInput.availableData },
    executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
exit(cli.run(Array(CommandLine.arguments.dropFirst())))
