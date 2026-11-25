import Foundation

/// Arguments of /usr/bin/ssh. Host key checking is always strict, whatever the user's ssh config says.
public enum SSHCommand {
    /// The command line wins over the config: ssh takes the first value it sees.
    static let options = [
        "StrictHostKeyChecking=yes", "BatchMode=yes", "NoHostAuthenticationForLocalhost=no", "VerifyHostKeyDNS=no",
        "UpdateHostKeys=no", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "Tunnel=no", "PermitLocalCommand=no",
        "ControlMaster=no", "ControlPath=none", "RemoteCommand=none", "RequestTTY=no", "StdinNull=no",
        "ForkAfterAuthentication=no", "SessionType=default", "LogLevel=INFO",
        "ConnectTimeout=15", "ServerAliveInterval=15", "ServerAliveCountMax=3",
    ]

    /// nil: the server's settings or a word of the command are not safe.
    /// `extra` comes first (tests point ssh at their own config and keys).
    public static func args(_ s: RemoteServer, command: String, extra: [String] = []) -> [String]? {
        guard s.problem == nil else { return nil }
        var a = options.flatMap { ["-o", $0] } + extra
        if s.port != 0 { a += ["-p", String(s.port)] }
        if !s.user.isEmpty { a += ["-l", s.user] }
        return a + ["--", s.host, command]
    }

    /// Command that calls an operation of the installed runner. Words are ids, numbers and safe paths — nothing to quote.
    public static func runner(_ s: RemoteServer, _ words: [String]) -> String? {
        guard s.problem == nil, words.allSatisfy({ RemoteServer.matches($0, "[A-Za-z0-9._/-]+") }) else { return nil }
        // /bin/sh: the login shell may be fish or csh.
        return (["exec", "/bin/sh", runnerPath(s)] + words).joined(separator: " ")
    }

    static func runnerPath(_ s: RemoteServer) -> String { "\(s.folder)/bin/\(RemoteRunner.fileName)" }

    /// Puts the runner script (stdin) into the TrackTasks folder.
    public static func install(_ s: RemoteServer) -> String {
        let bin = "\(s.folder)/bin", tmp = "\(bin)/new-\(RemoteRun.newID())"
        return "exec /bin/sh -c 'umask 077; mkdir -p \(bin) && cat > \(tmp) && mv -f \(tmp) \(runnerPath(s))'"
    }

    /// One word of a POSIX shell command.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public enum Failure: Equatable, Sendable {
        case unknownHostKey, changedHostKey, auth, noConnection

        public var text: String {
            switch self {
            case .unknownHostKey: "Ключ сервера неизвестен: запуск заблокирован. Проверь отпечаток и добавь ключ в known_hosts сам (например, подключись к серверу через ssh в терминале)"
            case .changedHostKey: "Ключ сервера изменился: запуск заблокирован, соединение могли подменить. Выясни причину и исправь known_hosts сам"
            case .auth: "Сервер не принял вход. Нужен вход по ключу без вопросов (ssh-agent или IdentityFile)"
            case .noConnection: "Нет связи с сервером"
            }
        }
        /// Waiting doesn't help.
        public var isFinal: Bool { self == .unknownHostKey || self == .changedHostKey }
    }

    /// nil: the connection worked, `status` belongs to the remote command.
    public static func failure(status: Int32, stderr: String) -> Failure? {
        guard status == 255 else { return nil }
        let e = stderr
        if e.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || e.contains("REVOKED HOST KEY")
            || (e.contains("host key for") || e.contains("Host key for")) && e.contains("has changed") { return .changedHostKey }
        if e.contains("Host key verification failed") || e.contains("you have requested strict checking") { return .unknownHostKey }
        if e.contains("Permission denied (") || e.contains("Too many authentication failures") { return .auth }
        return .noConnection
    }
}
