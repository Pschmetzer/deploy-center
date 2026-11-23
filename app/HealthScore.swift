// Deploy Center — the health score of a project, 0-100, with the same four parts as `deploys health`
// (docs/CLI.md): failures 40, recovery 25, freshness 20, CI 15. A part without data is left out and
// the rest scaled to 100, so a missing fact never counts as good or bad. Read from this Mac's history.

import SwiftUI

enum HealthScore {
    struct Part: Equatable { let points: Double?; let max: Double }
    struct Result: Equatable, Identifiable {
        let platform: String
        let name: String
        /// nil when no part had data.
        let score: Int?
        let deploys: Int
        let failures: Int
        let openOutage: Bool
        let parts: [String: Part]
        var id: String { platform + "/" + name }
        var rating: String? { score.map { $0 >= 80 ? "good" : ($0 >= 50 ? "watch" : "poor") } }
        var ratingText: String {
            switch rating {
            case "good": return L("good", "gut")
            case "watch": return L("watch", "beobachten")
            case "poor": return L("poor", "schlecht")
            default: return L("no data", "keine Daten")
            }
        }
    }

    /// One project's score (the formula is shared/HealthFormula.swift). `ci`: green, none, pending or red.
    static func score(platform: String, name: String, entries: [JournalEntry], now: Date = Date(), days: Int = 30, ci: String? = nil) -> Result {
        let events: [HealthFormula.Event] = entries.filter { $0.platform == platform && $0.name == name }.compactMap { x in
            switch x.kind {
            case .live, .forced: return .init(x.at, .good)
            case .failed: return .init(x.at, .failed)
            case .rollback: return .init(x.at, .rollback)
            default: return nil
            }
        }
        let o = HealthFormula.score(events, now: now, days: days, ci: ci)
        return Result(platform: platform, name: name, score: o.score, deploys: o.deploys, failures: o.failures, openOutage: o.openOutage,
                      parts: o.parts.mapValues { Part(points: $0.points, max: $0.max) })
    }

    /// Every project with a deploy or failure in the last 365 days, the worst first, and the average.
    static func all(_ entries: [JournalEntry], now: Date = Date(), days: Int = 30, ci: [String: String] = [:]) -> (rows: [Result], average: Int?) {
        let year = now.addingTimeInterval(-365 * 86400)
        var seen = Set<String>(), keys: [(String, String)] = []
        for x in entries where x.at >= year && [.live, .forced, .failed].contains(x.kind) {
            if seen.insert(x.platform + "/" + x.name).inserted { keys.append((x.platform, x.name)) }
        }
        let rows = keys.map { score(platform: $0.0, name: $0.1, entries: entries, now: now, days: days, ci: ci[$0.0 + "/" + $0.1]) }
            .sorted { ($0.score ?? 101) != ($1.score ?? 101) ? ($0.score ?? 101) < ($1.score ?? 101) : $0.name < $1.name }
        let s = rows.compactMap(\.score)
        return (rows, s.isEmpty ? nil : Int((Double(s.reduce(0, +)) / Double(s.count)).rounded()))
    }
}

/// One project's line in the card.
struct HealthScoreRow: View {
    let row: HealthScore.Result
    private var label: String {
        let score: String = row.score.map { L("score \($0)", "Wert \($0)") } ?? ""
        return Demo.mask(row.name) + ", " + score + ", " + row.ratingText
    }
    var body: some View {
        HStack {
            Text(Demo.mask(row.name)).lineLimit(1)
            Spacer()
            if row.openOutage { Text(L("failure open", "Fehler offen")).font(.caption).foregroundStyle(Color.warningText) }
            Text(row.score.map(String.init) ?? "–").monospacedDigit().bold()
            Text(row.ratingText).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// The card in Settings → Platforms: the average and the weakest projects.
struct HealthScoreCard: View {
    @State private var result: (rows: [HealthScore.Result], average: Int?)?

    var body: some View {
        Section(L("Health score (30 days)", "Gesundheitswert (30 Tage)")) {
            if let r = result, !r.rows.isEmpty {
                if let a = r.average {
                    Text(L("Average \(a) of 100", "Durchschnitt \(a) von 100")).font(.callout.weight(.semibold))
                }
                ForEach(Array(r.rows.prefix(5))) { HealthScoreRow(row: $0) }
                Text(L("Failures 40, recovery 25, freshness 20 points; CI is left out here. Same formula as `deploys health`.",
                       "Fehler 40, Wiederherstellung 25, Aktualität 20 Punkte; CI fehlt hier. Dieselbe Formel wie `deploys health`."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("No deploys in the history yet.", "Noch keine Deploys im Verlauf.")).foregroundStyle(.secondary)
            }
        }
        .task { result = HealthScore.all(Journal.load(limit: .max)) }
    }
}
