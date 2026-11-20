// Deploy Center — The week at a glance in the history window: the figures of the CLI's `deploys digest`,
// from this Mac's journal alone (JournalStats.outcomes). Nothing is sent anywhere.

import SwiftUI

struct WeekDigest {
    /// Deploys that went somewhere, failures, rollbacks and forced starts of the last `days` days.
    var deploys = 0, failed = 0, rollbacks = 0, forced = 0
    /// The same figures one period earlier, for the arrow.
    var previousDeploys = 0, previousFailed = 0
    /// Calendar weekday (1 = Sunday) with the most deploys, and how many.
    var busiestWeekday: Int?
    var busiestCount = 0
    /// Projects by number of deploys, most first (at most five).
    var projects: [(name: String, count: Int)] = []
    /// The newest failures, newest first (at most three).
    var latestFailures: [JournalEntry] = []
    var days = 7

    /// Failed share of the deploys, 0...1; nil without a deploy.
    var failRate: Double? { deploys > 0 ? Double(failed) / Double(deploys) : nil }
    var isEmpty: Bool { deploys == 0 }

    nonisolated static func make(_ list: [JournalEntry], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> WeekDigest {
        let p = JournalStats.periods(list, days: days, now: now)
        let recent = JournalStats.outcomes(p.recent), before = JournalStats.outcomes(p.before)
        var d = WeekDigest(days: days)
        d.deploys = recent.count
        d.failed = recent.filter { $0.kind == .failed }.count
        d.rollbacks = recent.filter { $0.kind == .rollback }.count
        d.forced = recent.filter { $0.kind == .forced }.count
        d.previousDeploys = before.count
        d.previousFailed = before.filter { $0.kind == .failed }.count
        var perDay: [Int: Int] = [:]
        for e in recent { perDay[calendar.component(.weekday, from: e.at), default: 0] += 1 }
        // Ties go to the earlier weekday, so the answer does not change between runs.
        if let top = perDay.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            d.busiestWeekday = top.key; d.busiestCount = top.value
        }
        var perProject: [String: Int] = [:]
        for e in recent { perProject[e.name, default: 0] += 1 }
        d.projects = perProject.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5).map { (name: $0.key, count: $0.value) }
        d.latestFailures = Array(recent.filter { $0.kind == .failed }.sorted { $0.at > $1.at }.prefix(3))
        return d
    }

    /// "+3", "−2", "±0": this period against the one before.
    nonisolated static func delta(_ now: Int, _ before: Int) -> String {
        now == before ? "±0" : (now > before ? "+\(now - before)" : "−\(before - now)")
    }

    nonisolated static func weekdayName(_ w: Int, calendar: Calendar = .current) -> String {
        let s = calendar.weekdaySymbols
        return s.indices.contains(w - 1) ? s[w - 1] : ""
    }

    /// Markdown for a chat or a note. Names go through `mask` (demo mode) and `scrub` (tokens).
    nonisolated func markdown(mask: (String) -> String = { $0 }, scrub: (String) -> String = { $0 }) -> String {
        var l = ["## " + L("Last \(days) days", "Letzte \(days) Tage"), ""]
        guard !isEmpty else { return (l + [L("No deploys.", "Keine Deploys.")]).joined(separator: "\n") }
        let rate = failRate.map { " (\(Int(($0 * 100).rounded())) %)" } ?? ""
        l.append("- " + L("Deploys: \(deploys) (\(Self.delta(deploys, previousDeploys)) against the week before)",
                           "Deploys: \(deploys) (\(Self.delta(deploys, previousDeploys)) gegenüber der Woche davor)"))
        l.append("- " + L("Failed: \(failed)\(rate)", "Fehlgeschlagen: \(failed)\(rate)"))
        l.append("- " + L("Rolled back: \(rollbacks), forced: \(forced)", "Zurückgerollt: \(rollbacks), erzwungen: \(forced)"))
        if let w = busiestWeekday {
            l.append("- " + L("Busiest day: \(Self.weekdayName(w)) (\(busiestCount))", "Meiste Deploys: \(Self.weekdayName(w)) (\(busiestCount))"))
        }
        if !projects.isEmpty {
            l += ["", "### " + L("Projects", "Projekte")]
            l += projects.map { "- \(mask($0.name)): \($0.count)" }
        }
        if !latestFailures.isEmpty {
            l += ["", "### " + L("Latest failures", "Letzte Fehler")]
            l += latestFailures.map { e in
                let why = (e.detail ?? "").split(separator: "\n").first.map { ": " + scrub(String($0)) } ?? ""
                return "- \(mask(e.name))\(why)"
            }
        }
        return l.joined(separator: "\n")
    }
}

/// The digest as a page of the history window.
struct WeekDigestView: View {
    let entries: [JournalEntry]
    var mask: (String) -> String = Demo.mask
    var scrub: (String) -> String = { $0 }

    var body: some View {
        let d = WeekDigest.make(entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("Last 7 days", "Letzte 7 Tage")).font(.headline)
                    Spacer()
                    CopyButton(title: L("Copy as Markdown", "Als Markdown kopieren")) { d.markdown(mask: mask, scrub: scrub) }
                        .disabled(d.isEmpty)
                }
                if d.isEmpty {
                    Text(L("No deploys in the last 7 days.", "Keine Deploys in den letzten 7 Tagen.")).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        figure(L("Deploys", "Deploys"), "\(d.deploys)", WeekDigest.delta(d.deploys, d.previousDeploys))
                        figure(L("Failed", "Fehlgeschlagen"), "\(d.failed)",
                               d.failRate.map { "\(Int(($0 * 100).rounded())) %" } ?? "")
                        figure(L("Rolled back", "Zurückgerollt"), "\(d.rollbacks)", "")
                        figure(L("Forced", "Erzwungen"), "\(d.forced)", "")
                    }
                    if let w = d.busiestWeekday {
                        Text(L("Busiest day: \(WeekDigest.weekdayName(w)) with \(d.busiestCount)",
                               "Meiste Deploys: \(WeekDigest.weekdayName(w)) mit \(d.busiestCount)")).font(.callout)
                    }
                    if !d.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Projects", "Projekte")).font(.subheadline.weight(.semibold))
                            ForEach(d.projects, id: \.name) { p in Text("\(mask(p.name)): \(p.count)").font(.callout) }
                        }
                    }
                    if !d.latestFailures.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Latest failures", "Letzte Fehler")).font(.subheadline.weight(.semibold))
                            ForEach(d.latestFailures) { e in
                                Text(mask(e.name) + ((e.detail ?? "").isEmpty ? "" : ": " + scrub(String((e.detail ?? "").prefix(120)))))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                Text(L("From this Mac's history only.", "Nur aus dem Verlauf dieses Macs."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func figure(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
            if !note.isEmpty { Text(note).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
