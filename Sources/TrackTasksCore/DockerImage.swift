import CryptoKit
import Foundation

/// The agent's own image: built by a button, nothing is downloaded otherwise. Part of the binary, so a build without
/// resources has it too. The tag is a hash of the content: an updated recipe needs a new build.
public enum DockerImage {
    /// Pinned: the stream protocol of another version may differ.
    public static let claudeVersion = "2.1.325"
    public static var tag: String {
        "tracktasks-agent:" + SHA256.hash(data: Data(dockerfile.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static let proxyPath = "/opt/tracktasks/proxy.js"

    /// Read from stdin: there is no build context, nothing of the Mac gets in.
    public static let dockerfile = """
    FROM node:22-bookworm-slim
    RUN apt-get update && apt-get install -y --no-install-recommends git ripgrep ca-certificates && rm -rf /var/lib/apt/lists/*
    RUN npm install -g @anthropic-ai/claude-code@\(claudeVersion) && npm cache clean --force
    RUN mkdir -p \(ContainerSpec.sessionsDir) && chmod 1777 \(ContainerSpec.sessionsDir)
    ENV DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    COPY <<'TRACKTASKS_PROXY' \(proxyPath)
    \(proxy)
    TRACKTASKS_PROXY

    """

    /// CONNECT to port 443 of the listed names only. The address is resolved here and must be public: a listed name
    /// can't lead to the Mac or the local network.
    static let proxy = #"""
    const http = require('http'), net = require('net'), dns = require('dns');
    const allow = (process.env.TT_ALLOW || '').toLowerCase().split(',').filter(Boolean);
    const ok = h => allow.some(a => a.startsWith('.') ? h.endsWith(a) : h === a);
    const inner = new net.BlockList();
    for (const [a, n] of [['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
      ['172.16.0.0', 12], ['192.168.0.0', 16], ['224.0.0.0', 4], ['240.0.0.0', 4]]) inner.addSubnet(a, n);
    const server = http.createServer((q, r) => { r.writeHead(403); r.end('tracktasks: only https to listed domains\n'); });
    server.on('connect', (q, s, head) => {
      s.on('error', () => s.destroy());
      const no = why => s.end('HTTP/1.1 403 Forbidden\r\n\r\ntracktasks: ' + why + '\n');
      const m = /^([a-z0-9.-]+):443$/i.exec(q.url);
      if (!m || net.isIP(m[1]) || !ok(m[1].toLowerCase())) return no('domain is not listed');
      dns.lookup(m[1], { family: 4 }, (e, ip) => {
        if (e) return no('no such host');
        if (inner.check(ip)) return no('address is not public');
        const up = net.connect(443, ip, () => {
          s.write('HTTP/1.1 200 OK\r\n\r\n');
          up.write(head);
          up.pipe(s); s.pipe(up);
        });
        up.on('error', () => s.destroy());
        s.on('close', () => up.destroy());
        up.on('close', () => s.destroy());
      });
    });
    server.listen(3128, '0.0.0.0');
    """#
}

/// The only way out of an agent's container.
public struct DockerProxy: Equatable, Sendable {
    public static let defaultDomains = ["api.anthropic.com"]
    public static let alias = "tracktasks-proxy"
    public static let url = "http://\(alias):3128"

    public var image: String
    public var domains: [String]
    public init(image: String, domains: [String]) { self.image = image; self.domains = domains }

    /// Names separated by spaces, commas or lines; a leading dot means subdomains. nil = something isn't a domain.
    public static func parse(_ text: String) -> [String]? {
        let all = text.lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init)
        // The last label has a letter: not an IP address.
        let name = #"^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*$"#
        return all.allSatisfy { $0.range(of: name, options: .regularExpression) != nil } ? all : nil
    }

    public static func network(_ container: String) -> String { container + "-net" }
    public static func container(_ container: String) -> String { container + "-proxy" }

    public func networkArgs(_ name: String, instance: String, job: String) -> [String] {
        ["network", "create", "--internal"] + labels(instance, job) + [Self.network(name)]
    }

    /// Created in the ordinary network, then connected to the closed one: the proxy stands in both.
    public func createArgs(_ name: String, instance: String, job: String) -> [String] {
        ["create", "--pull", "never", "--rm", "--init", "--name", Self.container(name)] + labels(instance, job)
            + ["--user", "65534:65534", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only",
               "--pids-limit", "64", "--memory", "256m", "-e", "TT_ALLOW=" + domains.joined(separator: ","),
               "--entrypoint", "node", image, DockerImage.proxyPath]
    }

    public func connectArgs(_ name: String) -> [String] {
        ["network", "connect", "--alias", Self.alias, Self.network(name), Self.container(name)]
    }

    private func labels(_ instance: String, _ job: String) -> [String] {
        ["--label", "\(ContainerSpec.instanceLabel)=\(instance)", "--label", "\(ContainerSpec.jobLabel)=\(job)"]
    }
}

/// Checks that only a Mac can run: in a container they always fail, so the branch is «не проверено», not red.
public enum ContainerVerify {
    public static func needsMac(_ command: String) -> Bool {
        command.range(of: #"(^|[\s;&|()/'"])(swift|xcodebuild|xcrun|xcode-select|simctl|swiftlint|tuist|fastlane|pod|codesign)($|[\s;&|()'"])"#,
                      options: .regularExpression) != nil
    }
}
