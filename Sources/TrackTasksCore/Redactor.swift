import Foundation

/// Removes keys and home paths from text before it leaves the app. Works by known formats:
/// a secret that looks like an ordinary word stays, so a person still has to look at the result.
public struct Redactor: Sendable {
    public static let mark = "[вычищено]"

    public struct Output: Equatable, Sendable {
        public var text: String
        /// Replacements made.
        public var secrets: Int
        public var paths: Int
    }

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home.hasSuffix("/") ? String(home.dropLast()) : home
    }

    public func clean(_ text: String) -> Output {
        // Keys first: they may contain slashes.
        var out = Output(text: text, secrets: 0, paths: 0)
        for r in Self.secretRules { out.secrets += r.apply(&out.text) }
        for r in homeRules + Self.pathRules { out.paths += r.apply(&out.text) }
        return out
    }

    // MARK: - Rules

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) {
            // Patterns are constants, covered by tests.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }

        func apply(_ s: inout String) -> Int {
            let m = NSMutableString(string: s)
            let n = regex.replaceMatches(in: m, range: NSRange(location: 0, length: m.length), withTemplate: template)
            if n > 0 { s = m as String }
            return n
        }
    }

    /// Start of a token; `\n` written as two characters also counts.
    private static let start = #"(?:(?<![A-Za-z0-9_])|(?<=\\[nrt]))"#
    private static let notMarked = #"(?!\[вычищено\])"#
    /// Quoted (also inside escaped JSON) or bare value.
    private static func value(_ minimum: Int) -> String {
        #"(?:\\?"\#(notMarked)[^"\\\n]{\#(minimum),}|'\#(notMarked)[^'\n]{\#(minimum),}|\#(notMarked)(?!["'`\\])[^\s"'`,;)\\]{\#(minimum),})"#
    }

    private static let secretRules: [Rule] = {
        // A cut block has no END line: everything that looks like its body goes.
        var rules = [
            Rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|(?:\s|\\[nr]|[A-Za-z0-9+/=:,-])*)"#, mark),
        ]
        // The prefix alone identifies these.
        let tokens = [
            #"sk-(?:ant|proj|svcacct|admin|or|lf)-[A-Za-z0-9_-]{16,}"#,     // Anthropic, OpenAI, OpenRouter, Langfuse
            #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
            #"gl(?:pat|dt|rt|ptt|cbt|oas|soat)-[A-Za-z0-9_.-]{16,}"#,
            #"(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}(?![A-Za-z0-9])"#,
            #"AIza[A-Za-z0-9_-]{35}"#, #"GOCSPX-[A-Za-z0-9_-]{20,}"#, #"ya29\.[A-Za-z0-9_-]{20,}"#,
            #"xox[a-z](?:\.xox[a-z])?-[A-Za-z0-9-]{10,}"#, #"xapp-[A-Za-z0-9-]{10,}"#,
            #"(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"#, #"whsec_[A-Za-z0-9+/=]{16,}"#,
            #"npm_[A-Za-z0-9]{30,}"#, #"pypi-[A-Za-z0-9_-]{30,}"#,
            #"hf_[A-Za-z0-9]{30,}"#, #"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
            #"do[opr]_v1_[a-f0-9]{32,}"#, #"sb[ps]_[A-Za-z0-9_-]{20,}"#, #"sb_secret_[A-Za-z0-9_-]{16,}"#,
            #"lin_(?:api|oauth)_[A-Za-z0-9]{20,}"#, #"ntn_[A-Za-z0-9]{30,}"#, #"dckr_pat_[A-Za-z0-9_-]{20,}"#,
            #"hv[sbr]\.[A-Za-z0-9_-]{20,}"#, #"AGE-SECRET-KEY-1[A-Z0-9]{20,}"#, #"gsk_[A-Za-z0-9]{30,}"#, #"xai-[A-Za-z0-9]{30,}"#,
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#,    // JWT
            #"hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]+"#,
            #"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+"#,
        ]
        rules += tokens.map { Rule($0, mark) }
        // Common beginnings: only as separate words.
        rules.append(Rule(start + #"sk-[A-Za-z0-9_-]{20,}"#, mark))
        rules.append(Rule(start + #"SK[a-f0-9]{32}(?![A-Za-z0-9])"#, mark))
        rules.append(Rule(#"(?:(?<![0-9])|(?<=bot))\d{8,10}:[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"#, mark))     // Telegram
        // Login in a URL.
        rules.append(Rule(#"([A-Za-z][A-Za-z0-9+.-]{1,20}://)\#(notMarked)[^\s/@:"'<>]*:[^\s/@"'<>]+@"#, "$1\(mark)@"))
        rules.append(Rule(#"(https?://)\#(notMarked)[^\s/@:"'<>]{16,}@"#, "$1\(mark)@"))
        rules.append(Rule(#"\b(Bearer|Basic)(\s+)\#(notMarked)[A-Za-z0-9._~+/=-]{12,}"#, "$1$2\(mark)", .caseInsensitive))
        rules.append(Rule(#"\b(AccountKey|SharedAccessKey|SharedAccessSignature)=\#(notMarked)[^\s;"']+"#, "$1=\(mark)", .caseInsensitive))
        // name = value, "name": "value", --name value.
        let name = #"(?:api[_-]?key|access[_-]?key|private[_-]?key|encryption[_-]?key|signing[_-]?key|secret|token|passw(?:or)?d|passphrase|credentials?|пароль|токен|секрет)"#
        rules.append(Rule(#"((?<![\w-])--?[\w-]{0,30}?\#(name)[\w-]{0,30}[ =]{1,4})\#(value(4))"#, "$1\(mark)", .caseInsensitive))
        rules.append(Rule(#"(\#(name)[\w-]{0,30}(?:\\?["'`*]){0,3}[ \t]{0,4}(?::=|=>|[:=])[ \t`*]{0,4})\#(value(4))"#, "$1\(mark)", .caseInsensitive))
        return rules
    }()

    /// Every spelling of this home folder, case ignored like the file system does.
    private var homeRules: [Rule] {
        guard home.count > 1 else { return [] }
        func literal(_ s: String, _ replacement: String, end: String) -> Rule {
            Rule(NSRegularExpression.escapedPattern(for: s) + end, replacement, .caseInsensitive)
        }
        let end = #"(?![\w-])"#
        let trimmed = home.drop { $0 == "/" }
        // Claude Code names session folders this way.
        let dashed = String(home.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let percent = home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? home
        return [
            literal(home, "~", end: end),
            literal(percent, "~", end: end),
            literal(home.replacingOccurrences(of: "/", with: "\\/"), "~", end: end),
            literal(home.replacingOccurrences(of: "/", with: "%2F"), "~", end: end),
            literal(home.replacingOccurrences(of: " ", with: "\\ "), "~", end: end),
            literal(trimmed.replacingOccurrences(of: "/", with: "__"), "~", end: "(?![A-Za-z0-9])"),
            literal(dashed, "~", end: "(?![A-Za-z0-9])"),
        ]
    }

    /// Homes of other people and machines, and temporary folders (their names identify the account).
    private static let pathRules = [
        Rule(#"(?:(?<![\w.~-])|(?<=\\[nrt])|(?<=-[ILF]))/(?:Users|home)/(?!Shared\b)[^\s/\\"'`<>()\[\]:;,]+"#, "~"),
        Rule(#"\\/(?:Users|home)\\/(?!Shared\b)[^\s/\\"'`<>()\[\]:;,]+"#, "~"),
        Rule(#"%2F(?:Users|home)%2F(?!Shared\b)[^\s/%\\"'`<>()&]+"#, "~"),
        Rule(#"(?:/private)?/var/folders/[^\s/"'`]+/[^\s/"'`]+"#, "\\$TMPDIR"),
    ]
}
