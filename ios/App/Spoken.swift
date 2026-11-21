// Deploy Center for iPhone — The sentences Siri and Shortcuts say about the last state read.
// Pure: no UIKit, no AppIntents, so ios/test.sh compiles and checks it on a Mac.

import Foundation

enum Spoken {
    /// One answer for "what waits": PRs and projects waiting, failures by name, and how old the state is.
    static func waiting(_ projects: [PhoneProject], at: Date?, now: Date = Date(), hideNames: Bool = false) -> String {
        // The same rule and count as the app and the widgets (PhoneStore.waitingPRs).
        let waiting = projects.waitingOnly, failed = projects.filter(\.failed)
        let prs = projects.waitingPRCount
        var out = waiting.isEmpty ? L("Nothing waits.", "Nichts wartet.")
            : L("\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).",
                "\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) \(prs == 1 ? "wartet" : "warten") in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).")
        if !failed.isEmpty { out += " " + failures(failed, hideNames: hideNames) }
        return out + age(at, now: now)
    }
    /// With "Unlock on open" on, Siri and Shortcuts say numbers only: the names are behind the app lock.
    static func failures(_ failed: [PhoneProject], hideNames: Bool = false) -> String {
        if hideNames, !failed.isEmpty {
            return L("\(plural(failed.count, ("project", "Projekt"), ("projects", "Projekte"))) failed. Open the app for the names.",
                     "\(plural(failed.count, ("project", "Projekt"), ("projects", "Projekte"))) \(failed.count == 1 ? "ist" : "sind") fehlgeschlagen. Die Namen zeigt die App.")
        }
        let names = failed.prefix(5).map(\.name).joined(separator: ", ") + (failed.count > 5 ? L(" and \(failed.count - 5) more", " und \(failed.count - 5) weitere") : "")
        return failed.isEmpty ? L("Nothing failed.", "Nichts ist fehlgeschlagen.")
            : L("Failed: \(names).", "Fehlgeschlagen: \(names).")
    }
    /// A state older than this gets its age said; a fresh one is just the answer (IDEEN-12 C30).
    static let ageSaidAfter: TimeInterval = 15 * 60
    static func age(_ at: Date?, now: Date = Date()) -> String {
        guard let at, now.timeIntervalSince(at) > ageSaidAfter else { return "" }
        let rel = at.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: appLocale))
        return L(" As of \(rel); open the app for the newest state.", " Stand \(rel); die App zeigt den neuesten.")
    }
}
