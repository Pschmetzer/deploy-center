// Deploy Center — Demo mode in texts the app did not build itself (toasts, messages, logs, commit lines).

import Foundation

extension Demo {
    /// Every project name, repo and domain in `text` replaced by its stand-in, longest first so
    /// "shop-api" is not cut into "shop" + "-api". Without demo mode the text stays as it is.
    /// Only for the screen: what goes to the clipboard stays real.
    static func scrub(_ text: String, items: [Item]) -> String {
        guard on, !text.isEmpty else { return text }
        var words = Set<String>()
        for i in items {
            words.insert(i.name)
            if let r = i.repo {
                words.insert(r)
                if let short = r.split(separator: "/").last { words.insert(String(short)) }
                if let owner = r.split(separator: "/").first { words.insert(String(owner)) }
            }
            if let d = i.domain { words.insert(d) }
        }
        // One pass, so a stand-in is never replaced again.
        let list = words.filter { $0.count >= 3 }.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
        guard !list.isEmpty, let re = regex(for: list) else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hit = ns.substring(with: m.range)
            out += mask(list.first { $0.caseInsensitiveCompare(hit) == .orderedSame } ?? hit)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// The pattern for a set of names, built once per set: a build log scrubs up to 2000 lines.
    private static func regex(for list: [String]) -> NSRegularExpression? {
        let key = list.joined(separator: "\u{1}")
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache, c.key == key { return c.re }
        guard let re = try? NSRegularExpression(pattern: list.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"),
                                                options: .caseInsensitive) else { return nil }
        cache = (key, re)
        return re
    }
    nonisolated(unsafe) private static var cache: (key: String, re: NSRegularExpression)?
    private static let cacheLock = NSLock()

    /// A person's name in demo mode: a stand-in, like project names.
    static func person(_ s: String?) -> String? { s.map { on ? mask($0) : $0 } }
}
