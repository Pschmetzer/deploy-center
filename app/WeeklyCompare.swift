// Deploy Center — the last 7 days against the 7 before, for the weekly report: deploys, failures,
// failed share, time to recover and build cost, each with an arrow. Pure rules, then a card.

import SwiftUI

enum WeeklyCompare {
    struct Row: Equatable { let title: String; let now: String; let before: String; let arrow: String; let better: Bool? }

    struct Figures: Equatable {
        let deploys: Int, failed: Int
        let failRate: Double?
        let restore: Double?
        init(_ list: [JournalEntry]) {
            let o = JournalStats.outcomes(list)
            deploys = o.filter { $0.kind == .live || $0.kind == .forced }.count
            failed = o.filter { $0.kind == .failed }.count
            let d = JournalStats.dora(list, days: 7)
            failRate = d.failRate; restore = d.restoreMedian
        }
    }

    /// ↑ above +5 %, ↓ below −5 %, else →; nil when there is no before to compare to.
    static func arrow(now: Double, before: Double) -> String {
        guard before > 0 else { return now > 0 ? "↑" : "→" }
        return CostInsights.arrow((now - before) / before * 100)
    }

    static func rows(_ list: [JournalEntry], costs: Costs? = nil, now: Date = Date()) -> [Row] {
        let p = JournalStats.periods(list, days: 7, now: now)
        let a = Figures(p.recent), b = Figures(p.before)
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f %%", $0 * 100) } ?? "–" }
        func dur(_ v: Double?) -> String { v.map { $0 >= 3600 ? String(format: "%.1f h", $0 / 3600) : "\(Int($0 / 60)) min" } ?? "–" }
        var out = [
            Row(title: L("Deploys", "Deploys"), now: "\(a.deploys)", before: "\(b.deploys)", arrow: arrow(now: Double(a.deploys), before: Double(b.deploys)), better: nil),
            Row(title: L("Failed", "Fehlgeschlagen"), now: "\(a.failed)", before: "\(b.failed)", arrow: arrow(now: Double(a.failed), before: Double(b.failed)),
                better: a.failed == b.failed ? nil : a.failed < b.failed),
            Row(title: L("Failed share", "Anteil Fehler"), now: pct(a.failRate), before: pct(b.failRate), arrow: arrow(now: a.failRate ?? 0, before: b.failRate ?? 0),
                better: (a.failRate ?? 0) == (b.failRate ?? 0) ? nil : (a.failRate ?? 0) < (b.failRate ?? 0)),
            Row(title: L("Back to good (median)", "Wieder gut (Median)"), now: dur(a.restore), before: dur(b.restore),
                arrow: arrow(now: a.restore ?? 0, before: b.restore ?? 0), better: a.restore == nil || b.restore == nil ? nil : (a.restore! <= b.restore!)),
        ]
        if let c = costs, let t = CostInsights.trend(c.days, today: CostsSheet.today()) {
            out.append(Row(title: L("Build cost", "Build-Kosten"), now: String(format: "%+.0f %%", t), before: "", arrow: CostInsights.arrow(t), better: t > 5 ? false : (t < -5 ? true : nil)))
        }
        return out
    }

    /// The week before in a few words, to put after the weekly notification; nil with nothing in it.
    static func beforeNote(_ list: [JournalEntry], now: Date = Date()) -> String? {
        let b = Figures(JournalStats.periods(list, days: 7, now: now).before)
        guard b.deploys + b.failed > 0 else { return nil }
        return L("week before: \(b.deploys) deploys, \(b.failed) failed", "Woche davor: \(b.deploys) Deploys, \(b.failed) fehlgeschlagen")
    }

    static func markdown(_ rows: [Row]) -> String {
        (["| | " + L("Last 7 days", "Letzte 7 Tage") + " | " + L("Week before", "Woche davor") + " |", "| --- | ---: | ---: |"]
         + rows.map { "| \($0.title) | \($0.now) \($0.arrow) | \($0.before) |" }).joined(separator: "\n") + "\n"
    }
}

struct WeeklyCompareCard: View {
    let entries: [JournalEntry]
    var costs: Costs?
    var body: some View {
        let rows = WeeklyCompare.rows(entries, costs: costs)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("This week against the week before", "Diese Woche gegen die Woche davor")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                CopyButton(title: L("Copy", "Kopieren")) { WeeklyCompare.markdown(rows) }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(rows, id: \.title) { r in
                    GridRow {
                        Text(r.title)
                        Text(r.now + " " + r.arrow).bold().foregroundStyle(r.better == true ? Color.good : (r.better == false ? Color.warningText : Color.primary))
                        Text(r.before).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(r.title + ": " + r.now + (r.before.isEmpty ? "" : L(", before ", ", davor ") + r.before))
                }
            }
        }
    }
}
