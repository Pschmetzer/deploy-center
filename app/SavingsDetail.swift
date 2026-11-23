// Deploy Center — What the figures of the savings banner stand for, for their popovers.

import SwiftUI

enum SavingsDetail {
    /// Where the saved amount comes from: minutes per platform, the price, and that it is an estimate.
    static func amountLines(_ l: LedgerReport) -> [String] {
        var out: [String] = []
        if l.vercelMinutes >= 1 { out.append("Vercel: " + SavingsFormat.minutes(l.vercelMinutes) + " " + L("build minutes", "Build-Minuten")) }
        if l.renderMinutes >= 1 { out.append("Render: " + SavingsFormat.minutes(l.renderMinutes) + " " + L("pipeline minutes", "Pipeline-Minuten")) }
        if let usd = l.usd, usd > 0 {
            out.append(L("Priced at ", "Bepreist mit ") + SavingsFormat.usd(usd) + (l.usdComplete ? "" : L(" (some projects have no price yet)", " (für manche Projekte fehlt noch ein Preis)")))
        }
        out.append(L("An estimate from the builds skipped since auto-deploy was turned off.", "Eine Schätzung aus den Builds, die seit dem Abschalten von Auto-Deploy übersprungen wurden."))
        return out
    }

    /// The projects with the most skipped builds, at most five, then how many more there are.
    static func skippedLines(_ l: LedgerReport, mask: (String) -> String = { $0 }) -> [String] {
        let rows = l.projects.filter { $0.skipped > 0 }.sorted { $0.skipped > $1.skipped }
        var out = rows.prefix(5).map { mask($0.name) + ": " + SavingsFormat.count($0.skipped) }
        if rows.count > 5 { out.append(L("and \(rows.count - 5) more projects", "und \(rows.count - 5) weitere Projekte")) }
        if out.isEmpty { out.append(L("No build was skipped yet.", "Noch kein Build übersprungen.")) }
        return out
    }
}

/// A figure in the banner that opens a small popover with its lines.
struct FigureButton: View {
    let title: String
    let lines: [String]
    @State private var open = false

    var body: some View {
        Button(title) { open.toggle() }
            .buttonStyle(.link).font(.callout.weight(.semibold))
            .accessibilityHint(L("Shows where this number comes from", "Zeigt, woher diese Zahl kommt"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) { ForEach(lines, id: \.self) { Text($0).font(.callout) } }
                    .padding(10).frame(maxWidth: 320, alignment: .leading)
            }
    }
}
