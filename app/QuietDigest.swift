// Deploy Center — Quiet hours: what would have notified is kept and comes as one note when they end.
// Failures are never held (Notify.post); this only bundles the good news.

import Foundation

enum QuietDigest {
    static let key = "quietHeld"
    static let id = "quiet-digest"
    /// A held line older than this belongs to an earlier night.
    static let maxAge: TimeInterval = 20 * 3600

    /// Seconds from `now` to the next full hour `to` (the end of the quiet hours), at least a minute.
    static func seconds(until to: Int, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: to, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        return max(60, next.timeIntervalSince(now))
    }

    /// "epoch|text" lines still of this night, plus the new one; the oldest fall out beyond 200.
    static func adding(_ text: String, to held: [String], now: Date = Date()) -> [String] {
        let fresh = held.filter { l in
            guard let t = l.split(separator: "|", maxSplits: 1).first.flatMap({ Double($0) }) else { return false }
            return now.timeIntervalSince1970 - t < maxAge
        }
        return Array((fresh + ["\(Int(now.timeIntervalSince1970))|" + text.replacingOccurrences(of: "\n", with: " ")]).suffix(200))
    }

    /// The note for the held lines: how many, and the first few. `neutral` (lock screen) says only the number.
    static func note(_ held: [String], neutral: Bool, shown: Int = 4) -> (title: String, body: String) {
        let texts = held.map { l in l.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? l }
        let n = texts.count
        let title = n == 1 ? L("1 update while it was quiet", "1 Meldung während der Ruhezeit")
                           : L("\(n) updates while it was quiet", "\(n) Meldungen während der Ruhezeit")
        if neutral { return (title, L("Open Deploy Center for details.", "Details im Deploy Center.")) }
        var lines = Array(texts.prefix(shown))
        if n > shown { lines.append(L("and \(n - shown) more", "und \(n - shown) weitere")) }
        return (title, lines.joined(separator: "\n"))
    }
}

/// The quiet hours setting in one place (`quietFrom`, `quietTo`: hours 0–23, both equal is off), so the notifications,
/// the voice, the digest and the settings text cannot disagree.
struct QuietHours: Equatable {
    static let fromKey = "quietFrom", toKey = "quietTo"
    var from: Int, to: Int
    static func current(_ d: UserDefaults = .standard) -> QuietHours { QuietHours(from: d.integer(forKey: fromKey), to: d.integer(forKey: toKey)) }
    func isQuiet(_ now: Date = Date(), calendar: Calendar = .current) -> Bool {
        Notify.quiet(hour: calendar.component(.hour, from: now), from: from, to: to)
    }
    /// Seconds until they end (at least a minute); only meaningful while `isQuiet`.
    func endsIn(_ now: Date = Date(), calendar: Calendar = .current) -> TimeInterval { QuietDigest.seconds(until: to, now: now, calendar: calendar) }
}
