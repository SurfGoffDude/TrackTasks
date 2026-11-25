import CryptoKit
import Foundation

/// Signatures of incoming events. Checked over raw bytes, before anything is parsed.
public enum EventSignature {
    /// Allowed difference of clocks, seconds.
    public static let window = 300

    public struct Stamp: Equatable, Sendable {
        public var time: Int
        public var nonce: String
    }

    public static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    public static func random(bytes: Int) -> String { hex((0..<bytes).map { _ in UInt8.random(in: 0...255) }) }
    public static func bodyHash(_ body: Data) -> String { hex(SHA256.hash(data: body)) }

    public static func sign(_ data: Data, secret: String) -> String {
        "sha256=" + hex(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(secret.utf8))))
    }

    static func signed(time: String, nonce: String, body: Data) -> Data { Data("\(time).\(nonce).".utf8) + body }

    /// `X-Hub-Signature-256`.
    public static func github(_ signature: String?, body: Data, secret: String) -> Bool {
        valid(signature, body, secret)
    }

    /// nil: wrong signature or a time out of the window.
    public static func webhook(time: String?, nonce: String?, signature: String?, body: Data, secret: String, now: Date) -> Stamp? {
        guard let time, let nonce, (1...11).contains(time.utf8.count), time.utf8.allSatisfy({ (48...57).contains($0) }), let t = Int(time),
              (16...128).contains(nonce.utf8.count),
              nonce.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              valid(signature, signed(time: time, nonce: nonce, body: body), secret),
              abs(now.timeIntervalSince1970 - Double(t)) <= Double(window) else { return nil }
        return Stamp(time: t, nonce: nonce)
    }

    /// Constant-time comparison; an empty secret signs nothing.
    private static func valid(_ signature: String?, _ data: Data, _ secret: String) -> Bool {
        guard !secret.isEmpty, let signature, signature.hasPrefix("sha256=") else { return false }
        let chars = Array(signature.utf8.dropFirst(7))
        guard chars.count == 64 else { return false }
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        var mac = [UInt8]()
        for i in stride(from: 0, to: 64, by: 2) {
            guard let a = digit(chars[i]), let b = digit(chars[i + 1]) else { return false }
            mac.append(a << 4 | b)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: SymmetricKey(data: Data(secret.utf8)))
    }
}
