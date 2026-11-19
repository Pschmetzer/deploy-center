// Deploy Center — The waits and intervals the store works by, named once.

import Foundation

enum Timing {
    /// The Autofix list is read again at most this often (seconds).
    static let autofixSync: TimeInterval = 180
    /// After the Autofix list failed, the next read waits this long (seconds).
    static let autofixBackoff: TimeInterval = 3600
    /// The tool check ("doctor") is repeated after this long (seconds).
    static let doctorEvery: TimeInterval = 1800
    /// Costs, triggers and budget are read again after this long (seconds).
    static let extrasEvery: TimeInterval = 3600
    /// How many messages (the bell) are kept: a run over 30 projects must not push everything older out.
    static let messageLimit = 200
    /// A manual reload (⌘R) reads costs and triggers again only after this long (seconds): they cost many calls.
    static let manualExtrasEvery: TimeInterval = 600
    /// A deploy whose answer stays unclear is asked again after this long (seconds).
    static let unsureWait: Double = 600
    /// A followed deploy counts as overdue after this long …
    static let followOverdue: Duration = .seconds(40 * 60)
    /// … and is let go after this long.
    static let followDeadline: Duration = .seconds(12 * 3600)
}
