import Foundation

// Build logs on the phone: obvious secrets masked before anything is shown or copied.
// A port of `af_mask` in the deploys CLI (same rules, same order); tests: ios/Tests/run.sh.
// Foundation only, no app types: the tests compile this file on its own.
// A help, not a guarantee: a token with no known prefix and no telling name still goes through.

enum LogMask {
    private static func re(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p) }

    private static let begin = #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY"#
    private static let end = #"-----END [A-Z0-9 ]*PRIVATE KEY"#
    private static let oneLineKey = #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----.*?-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"#

    /// The substitutions after the private-key handling, in af_mask's order. NSRegularExpression
    /// templates: `$1` for a group (empty when it did not match, as in perl), `[` is literal.
    static let rules: [(String, String)] = [
        // Known prefixes: Anthropic/OpenAI, Stripe, GitHub, GitLab, Slack, AWS, Google, npm, Render, JWT.
        (#"\b(sk-[A-Za-z0-9_-]{8,}|(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|(?:AKIA|ASIA)[A-Z0-9]{12,}|AIza[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{20,}|rnd_[A-Za-z0-9]{8,}|dop_v1_[A-Za-z0-9]{16,}|nfp_[A-Za-z0-9]{16,}|sbp_[A-Za-z0-9]{16,}|sb_secret_[A-Za-z0-9_-]{8,}|hf_[A-Za-z0-9]{20,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|re_[A-Za-z0-9]{20,}|sntrys_[A-Za-z0-9+/=_-]{20,}|[0-9]{1,9}\|[A-Za-z0-9]{40}|[0-9]{8,10}:[A-Za-z0-9_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+)"#, "[masked]"),
        // Webhook URLs are secrets by themselves: Slack (services, workflows, triggers), Discord, Teams (old and new),
        // Google Chat (the key and token are in the query), and a Telegram bot token in the path.
        (#"https?://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_/.-]+"#, "[masked webhook]"),
        (#"https?://(?:[a-z]+\.)?(?:discord|discordapp)\.com/api/(?:v\d+/)?webhooks/[A-Za-z0-9_/.-]+"#, "[masked webhook]"),
        (#"https?://[a-z0-9.-]+\.(?:webhook|office)\.com/(?:webhookb2|webhook)[A-Za-z0-9@./_-]*"#, "[masked webhook]"),
        (#"https?://chat\.googleapis\.com/v1/spaces/[^\s"\x27]+"#, "[masked webhook]"),
        (#"(api\.telegram\.org/(?:file/)?bot)[A-Za-z0-9:_-]+"#, "$1[masked]"),
        // NAME=value, NAME: value, "name": "value", Authorization: Bearer x, for names that say secret.
        (#"\b((?i:[A-Za-z0-9_.-]*?(?:token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key|private[_-]?key|[_-]key|accountkey|authorization|auth|credentials?|dsn))["\x27]?\s*[:=]\s*)((?i:bearer|basic|token|bot)\s+)?("[^"]*"|\x27[^\x27]*\x27|[^\s"\x27,;]+)"#, "$1$2[masked]"),
        // Bearer/Basic with no name before it, and whole cookies.
        (#"\b((?i:bearer|basic)\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[masked]"),
        (#"\b((?i:set-cookie|cookie)\s*:\s*).+"#, "$1[masked]"),
        // Signed URLs: the signature and credential parts of a query (S3, Azure SAS, GCS).
        (#"([?&](?i:sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential)=)[^&\s"\x27]+"#, "$1[masked]"),
        // --token x, --token=x (vercel, npm and most CLIs).
        (#"(--(?i:token|password|api-key|secret)(?:=|\s+))[^\s"\x27]+"#, "$1[masked]"),
        // user:password@ in a URL (database URLs).
        (#"(://[^/\s:@]+):[^/\s]+@(?=[^@/\s]+)"#, "$1:[masked]@"),
        // An email address, but not git@host (the user of an SSH clone URL: the error needs it).
        (#"\b(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[email]"),
    ]

    /// A line of a key's base64 body.
    private static let keyBody = #"^[A-Za-z0-9+/=]{16,}\s*$"#

    private struct Compiled { let oneLine: NSRegularExpression; let begin: NSRegularExpression; let end: NSRegularExpression; let body: NSRegularExpression
                              let rules: [(NSRegularExpression, String)] }
    /// nil when a pattern does not compile: then nothing is shown (fail closed, like af_mask without perl).
    private static let compiled: Compiled? = {
        guard let o = re(oneLineKey), let b = re(begin), let e = re(end), let k = re(keyBody) else { return nil }
        var out: [(NSRegularExpression, String)] = []
        for (p, t) in rules { guard let r = re(p) else { return nil }; out.append((r, t)) }
        return Compiled(oneLine: o, begin: b, end: e, body: k, rules: out)
    }()
    static var works: Bool { compiled != nil }

    static let maxLine = 4000

    private static func sub(_ r: NSRegularExpression, _ s: String, _ t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
    private static func has(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The lines with secrets masked; a private key over several lines becomes one line. nil: masking is unavailable.
    static func mask(_ lines: [String]) -> [String]? {
        guard let c = compiled else { return nil }
        var out: [String] = [], pem = false
        for full in lines {
            // One line over the cap is cut before any rule runs (quadratic backtracking on a line like "a.a.a.").
            let raw = full.count > maxLine ? String(full.prefix(maxLine)) + " […line cut, not scanned]" : full
            var l = sub(c.oneLine, raw, "[masked private key]")
            if pem { if has(c.end, l) { pem = false }; continue }
            if has(c.begin, l) { pem = true; out.append("[masked private key]"); continue }
            // An END without its BEGIN (a log cut or rotated in the middle): the key body above it goes too.
            if has(c.end, l) {
                while let last = out.last, has(c.body, last) { out.removeLast() }
                out.append("[masked private key]"); continue
            }
            for (r, t) in c.rules { l = sub(r, l, t) }
            out.append(l)
        }
        return out
    }
    static func mask(_ text: String) -> String? { mask(lines(text)).map { $0.joined(separator: "\n") } }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.hasSuffix("\r") ? $0.dropLast() : $0[...]) }
    }

    /// Colours (SGR), but also cursor moves and erases (CSI, any final byte) and window titles (OSC): a log tool
    /// can hide text behind them, and a colour code can split a secret so that no rule matches it.
    private static let ansi = re(#"\x1b\[[0-9;?<=>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]"#)
    static func stripANSI(_ s: String) -> String { ansi.map { sub($0, s, "") } ?? s }

    private static let errorWord = re(#"(?i)(\berror\b|\bfailed\b|\bfatal\b|\bexception\b|ERR!|\bexit(ed)? (with )?(status|code) [1-9])"#)

    /// The part worth reading on a phone: from a little before the first error line to a little after it,
    /// or the last lines when no line says error. Cut from lines that are already masked.
    static func excerpt(_ masked: [String], before: Int = 15, after: Int = 40, tail: Int = 60) -> (lines: [String], errorAt: Int?) {
        if let r = errorWord, let i = masked.firstIndex(where: { has(r, $0) }) {
            let lo = max(0, i - before), hi = min(masked.count, i + after + 1)
            return (Array(masked[lo..<hi]), i - lo)
        }
        return (Array(masked.suffix(tail)), nil)
    }

    // MARK: Provider log formats (pure, so the tests read fixtures)

    /// Vercel `/v3/deployments/{id}/events`: oldest first, text of each event, blank ones dropped.
    static func vercelLines(_ json: Any?) -> [String] {
        let events = (json as? [[String: Any]]) ?? []
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        return events.sorted { num($0["created"]) < num($1["created"]) }
            .compactMap { (($0["payload"] as? [String: Any])?["text"] as? String) ?? ($0["text"] as? String) }
            .flatMap { lines(stripANSI($0)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Render `/logs` read backward (newest first): oldest first, ANSI colours removed.
    static func renderLines(_ json: Any?) -> [String] {
        let logs = ((json as? [String: Any])?["logs"] as? [[String: Any]]) ?? []
        return logs.reversed().compactMap { $0["message"] as? String }.flatMap { lines(stripANSI($0)) }
    }
}
