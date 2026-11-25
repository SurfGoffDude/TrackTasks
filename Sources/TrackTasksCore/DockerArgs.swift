import Foundation

/// One container. Only the worktree is mounted: no home folder, no Docker socket, no `.git` of the main folder.
public struct ContainerSpec: Sendable {
    public enum Network: Equatable, Sendable {
        case none
        /// Docker network made by the app.
        case named(String)
    }

    public struct Limits: Equatable, Sendable {
        public var memoryMB = 4096
        public var cpus = 2.0
        public var pids = 512
        public var tmpMB = 1024
        public init() {}
    }

    public enum Problem: LocalizedError, Equatable {
        case path(String), root, value(String)
        public var errorDescription: String? {
            switch self {
            case .path(let p): "Путь нельзя подключить к контейнеру: \(p)"
            case .root: "Контейнер не запускается от root"
            case .value(let v): "Недопустимое значение для контейнера: \(v)"
            }
        }
    }

    public static let workspace = "/workspace"
    /// Temporary repository inside the container (tmpfs).
    /// Where an image keeps the agent's sessions: the folder must exist there, writable for any user
    /// (a new volume takes its rights from the image).
    public static let sessionsDir = "/home/agent/.claude"
    static let gitDir = "/tmp/tt/git"
    /// Content of `.git` as the container sees it; the real one, with the path to the main folder, is hidden under it.
    public static let gitLink = "gitdir: \(gitDir)\n"

    public static let instanceLabel = "tracktasks.instance"
    public static let jobLabel = "tracktasks.job"

    public var name: String
    public var image: String
    public var worktree: URL
    /// File with `gitLink`, outside the worktree.
    public var gitSeal: URL
    public var command: [String]
    /// This copy of the app; cleanup touches only containers with its label.
    public var instance: String
    public var job: String
    public var network = Network.none
    /// The network has `DockerProxy` in it.
    public var viaProxy = false
    public var limits = Limits()
    /// Variables whose values docker takes from its own environment: values never get into the arguments.
    public var secrets: [String] = []
    /// Docker volume with the agent's sessions; only for agent runs.
    public var sessions: String?
    public var uid: UInt32
    public var gid: UInt32

    public init(image: String, worktree: URL, gitSeal: URL, command: [String], instance: String, job: String,
                uid: UInt32 = getuid(), gid: UInt32 = getgid()) {
        name = "tracktasks-" + UUID().uuidString.lowercased()
        self.image = image
        self.worktree = worktree
        self.gitSeal = gitSeal
        self.command = command
        self.instance = instance
        self.job = job
        self.uid = uid
        self.gid = gid
    }

    /// `docker create …`. The container is started separately, so a stop between the two steps has something to remove.
    public func createArgs() throws -> [String] {
        guard uid != 0 else { throw Problem.root }
        // Values go to docker as separate arguments; a leading «-» would still be read as an option.
        for v in [image, instance, job] + secrets where v.isEmpty || v.hasPrefix("-") { throw Problem.value(v) }
        for s in secrets where s.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) == nil { throw Problem.value(s) }
        let net: String
        switch network {
        case .none: net = "none"
        case .named(let n):
            // Shares the network of the host or of another container.
            guard n.range(of: #"^tracktasks-[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Problem.value(n) }
            net = n
        }
        var a = ["create", "--pull", "never", "--rm", "--init", "-i", "--name", name,
                 "--label", "\(Self.instanceLabel)=\(instance)", "--label", "\(Self.jobLabel)=\(job)",
                 "--mount", try Self.bind(worktree, to: Self.workspace),
                 "--mount", try Self.bind(gitSeal, to: Self.workspace + "/.git") + ",readonly",
                 "--workdir", Self.workspace,
                 "--user", "\(uid):\(gid)", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "--read-only", "--tmpfs", "/tmp:rw,nosuid,nodev,mode=1777,size=\(limits.tmpMB)m",
                 "--pids-limit", "\(limits.pids)", "--memory", "\(limits.memoryMB)m",
                 "--memory-swap", "\(limits.memoryMB)m", "--cpus", "\(limits.cpus)",
                 "--network", net, "-e", "HOME=/tmp/home", "-e", "CI=1"]
        if viaProxy {
            for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { a += ["-e", "\(k)=\(DockerProxy.url)"] }
        }
        for s in secrets { a += ["-e", s] }
        if let v = sessions {
            guard v.range(of: #"^tracktasks-[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw Problem.value(v) }
            a += ["--mount", "type=volume,source=\(v),target=\(Self.sessionsDir)", "-e", "CLAUDE_CONFIG_DIR=\(Self.sessionsDir)"]
        }
        return a + ["--entrypoint", "/bin/sh", image, "-c", Self.entrypoint, "tracktasks"] + command
    }

    /// `--mount` is comma-separated, with quotes of its own.
    static func bind(_ url: URL, to target: String) throws -> String {
        let p = url.path
        guard p.hasPrefix("/"), p != "/", p.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"\n\r")) == nil else { throw Problem.path(p) }
        return "type=bind,source=\(p),target=\(target)"
    }

    /// Base snapshot for `git status` / `git diff` inside, then the command itself. Without git in the image the
    /// command still runs. Passed as an argument, not baked in, so a project's own image works too.
    /// Set up from `/`: in the workspace git fails until the folder its `.git` points to exists.
    static let entrypoint = """
    mkdir -p "$HOME" /tmp/tt
    if [ -n "$CLAUDE_CONFIG_DIR" ] && [ ! -w "$CLAUDE_CONFIG_DIR" ]; then
      echo "tracktasks: $CLAUDE_CONFIG_DIR is not writable: the image has no such folder open for any user" >&2
      exit 126
    fi
    if command -v git >/dev/null 2>&1; then
      export GIT_CONFIG_NOSYSTEM=1
      { cd / && git config --global --add safe.directory \(workspace) \
        && git config --global user.name agent && git config --global user.email agent@localhost \
        && git init -q --bare \(gitDir) && git --git-dir=\(gitDir) config core.bare false \
        && cd \(workspace) && git add -A && git commit -q --allow-empty --no-verify -m base; } >/dev/null 2>&1 \
        || echo 'tracktasks: no base git snapshot' >&2
    fi
    cd \(workspace) || exit 1
    exec "$@"
    """
}

/// What the host's git must not meet in a folder a container could write to.
public enum WorktreeSeal {
    /// `.git` of the worktree, remembered before the first run.
    public static func read(_ worktree: URL) -> Data? {
        try? SafeFolder(worktree).read(".git", limit: 4096)
    }

    private static func unreadable(_ path: String) -> String { "Не удалось прочитать \(path)" }

    /// nil = safe for git on the host. A replaced `.git` or a nested repository brings its own config, and git runs
    /// commands from it (fsmonitor, filters). The whole tree is checked, `node_modules` too: the agent picks folder names
    /// and edits .gitignore, so a skipped folder or depth would be the way around. Without stat it's ≈ 0.3 s per
    /// 70 000 files; call it once after a turn of the container, off the main thread, not before each git command.
    public static func problem(_ worktree: URL, sealed: Data) -> String? {
        guard read(worktree) == sealed else { return "Файл .git в worktree изменён" }
        guard let start = strdup(worktree.path) else { return unreadable(worktree.path) }
        defer { free(start) }
        var roots: [UnsafeMutablePointer<CChar>?] = [start, nil]
        guard let walk = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return unreadable(worktree.path) }
        defer { fts_close(walk) }
        errno = 0
        while let e = fts_read(walk) {
            switch Int32(e.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS: return unreadable(String(cString: e.pointee.fts_path))
            case FTS_DP: continue
            default: break
            }
            // Cheap check first: the name is four bytes long. Any case: the disk usually doesn't tell them apart.
            guard e.pointee.fts_level > 1, e.pointee.fts_namelen == 4 else { continue }
            let path = String(cString: e.pointee.fts_path)
            if path.lowercased().hasSuffix("/.git") { return "Вложенный git-репозиторий в worktree: \(path)" }
        }
        return errno == 0 ? nil : unreadable(worktree.path)
    }
}
