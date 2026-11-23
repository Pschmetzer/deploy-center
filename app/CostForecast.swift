// Deploy Center — per-project month forecast with a limit warning, and "what would this project
// cost on another host" from the build minutes the savings report already has. Pure rules first
// (tested in tests/app/insights.swift), the views after. Nothing here starts a build.

import SwiftUI

enum CostForecast {
    struct Line: Equatable {
        let name: String
        /// The 7 days scaled to the days of this month.
        let month: Double
        let budget: Double?
        /// The month's forecast over the budget; nil without a budget or below it.
        var over: Double? { budget.flatMap { month > $0 ? month - $0 : nil } }
        /// 0…1.5: how much of the budget the forecast uses.
        var share: Double? { budget.flatMap { $0 > 0 ? min(month / $0, 1.5) : nil } }
    }

    /// The forecast per project, the dearest first. Budgets are monthly, by `BudgetKey`.
    static func lines(_ c: Costs, budgets: [String: Double], daysInMonth: Int) -> [Line] {
        c.projects.filter { $0.build > 0 && $0.build.isFinite }
            .map { Line(name: $0.name, month: $0.build / 7 * Double(daysInMonth), budget: budgets[BudgetKey.key(platform: "vercel", name: $0.name)]) }
            .sorted { $0.month > $1.month }
    }

    /// The warning for a line over its budget, e.g. "≈ $12.00 over the budget of $30.00".
    static func warning(_ l: Line) -> String? {
        guard let over = l.over, let b = l.budget else { return nil }
        let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(uiLocale)
        return L("≈ \(over.formatted(usd)) over the budget of \(b.formatted(usd))", "≈ \(over.formatted(usd)) über dem Budget von \(b.formatted(usd))")
    }
}

enum PlatformSwitch {
    struct Option: Equatable {
        let name: String
        let from: String
        let to: String
        /// Build minutes a month at the current pace.
        let minutes: Double
        let costNow: Double
        let costThere: Double
        var difference: Double { costThere - costNow }
    }

    /// The price of a build minute per host (`vercel`, `render`), from ~/.config/deploys/prices.json.
    static func rates(_ data: Data?) -> [String: Double] {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for h in ["vercel", "render"] { if let v = o[h + "UsdPerMinute"] as? Double, v > 0, v.isFinite { out[h] = v } }
        return out
    }

    static var pricesURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys/prices.json") }

    /// Per project with minutes and a price for both hosts. A project without them is left out: no guessing.
    static func options(_ r: SimulateReport, rates: [String: Double]) -> [Option] {
        guard r.days > 0 else { return [] }
        return r.projects.compactMap { row in
            guard row.problem == nil, let avg = row.avgBuildMinutes, avg > 0, row.pushes > 0,
                  let now = rates[row.platform],
                  let other = (row.platform == "vercel" ? "render" : (row.platform == "render" ? "vercel" : nil)),
                  let there = rates[other] else { return nil }
            let minutes = row.pushes / r.days * 30 * avg
            return Option(name: row.name, from: row.platform, to: other, minutes: minutes, costNow: minutes * now, costThere: minutes * there)
        }.sorted { abs($0.difference) > abs($1.difference) }
    }
}

/// In the costs sheet: the month forecast per project and what a move would cost.
struct CostForecastCard: View {
    let costs: Costs
    @State private var budgets = ProjectBudgets.all()
    @ObservedObject private var savings = SavingsModel.shared

    var body: some View {
        let days = CostsSheet.daysInMonth(CostsSheet.today())
        let lines = CostForecast.lines(costs, budgets: budgets, daysInMonth: days).prefix(6)
        let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD")
        let moves = savings.simulation.map { PlatformSwitch.options($0, rates: PlatformSwitch.rates(try? Data(contentsOf: PlatformSwitch.pricesURL))) }?.prefix(3) ?? []
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Forecast for the month", "Prognose für den Monat")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(lines), id: \.name) { l in
                    HStack {
                        if l.over != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText).accessibilityHidden(true) }
                        Text(Demo.mask(l.name)).lineLimit(1)
                        Spacer()
                        if let w = CostForecast.warning(l) { Text(w).font(.caption).foregroundStyle(Color.warningText) }
                        Text("≈ " + l.month.formatted(usd)).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
                if !moves.isEmpty {
                    Text(L("On the other host (estimate, your prices per build minute)", "Beim anderen Host (Schätzung, Ihre Preise je Build-Minute)")).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(Array(moves), id: \.name) { m in
                        HStack {
                            Text(Demo.mask(m.name)).lineLimit(1)
                            Spacer()
                            Text(m.to.capitalized + " ≈ " + m.costThere.formatted(usd) + " (" + (m.difference >= 0 ? "+" : "−") + abs(m.difference).formatted(usd) + ")").monospacedDigit()
                        }
                        .font(.callout).accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
