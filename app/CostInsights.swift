// Deploy Center — small cost helpers for the costs sheet: a 7-day sparkline, a budget per project
// with a traffic light, the "what if one deploy a day" estimate and a Markdown report. Pure rules
// first (tested in tests/app-tests.swift), the views after.

import SwiftUI

enum CostInsights {
    enum Light: String { case green, yellow, red }

    /// A project's pace for a month: its 7 days scaled to 30.
    static func monthly(week: Double) -> Double { week / 7 * 30 }

    /// Green up to 80 % of the budget, yellow up to the budget, red above. Nil without a budget.
    static func light(week: Double, budget: Double) -> Light? {
        guard budget > 0, week.isFinite else { return nil }
        let r = monthly(week: week) / budget
        return r <= 0.8 ? .green : (r <= 1 ? .yellow : .red)
    }

    /// What the builds of the week would have cost with at most one build per project and day.
    /// Only for projects whose builds were all counted (`perBuild`), so it never guesses.
    static func onceADaySaving(_ c: Costs) -> Double {
        c.projects.reduce(0) { sum, p in
            guard let n = p.builds, n > 7, let per = c.perBuild(p.name) else { return sum }
            return sum + Double(n - 7) * per
        }
    }

    /// The last 7 days against the 7 before: the change in percent, nil with fewer than 14 days or a
    /// previous week without cost (a percentage of nothing says nothing).
    static func trend(_ days: [Costs.Day]) -> Double? {
        guard days.count >= 14 else { return nil }
        let recent = days.suffix(7).map(\.build).reduce(0, +)
        let before = days.suffix(14).prefix(7).map(\.build).reduce(0, +)
        guard before > 0, recent.isFinite, before.isFinite else { return nil }
        return (recent - before) / before * 100
    }
    /// ↑ above +5 %, ↓ below −5 %, else →.
    static func arrow(_ pct: Double) -> String { pct > 5 ? "↑" : (pct < -5 ? "↓" : "→") }

    /// The last `n` days' build costs, oldest first, for the sparkline.
    static func series(_ days: [Costs.Day], _ n: Int = 7) -> [Double] { days.suffix(n).map(\.build) }

    /// A Markdown report of the costs; project names are included only when `names` is true.
    static func report(_ c: Costs, budget: Double, today: String, names: Bool = true) -> String {
        let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD")
        var out = ["# " + L("Build costs", "Build-Kosten") + " — " + today, ""]
        out.append(L("Last 7 days: ", "Letzte 7 Tage: ") + c.week.formatted(usd))
        out.append(L("≈ per month at this pace: ", "≈ pro Monat bei diesem Tempo: ") + monthly(week: c.week).formatted(usd))
        if budget > 0 { out.append(L("Monthly budget: ", "Monatsbudget: ") + budget.formatted(usd)) }
        out += ["", "| " + L("Project", "Projekt") + " | " + L("Builds", "Builds") + " | USD |", "| --- | ---: | ---: |"]
        for (i, p) in c.projects.filter({ $0.build > 0 }).sorted(by: { $0.build > $1.build }).enumerated() {
            out.append("| " + (names ? p.name : "#\(i + 1)") + " | " + (p.builds.map(String.init) ?? "–") + " | " + p.build.formatted(usd) + " |")
        }
        return out.joined(separator: "\n") + "\n"
    }
}

extension Costs {
    /// The build costs of the 7 days, as the sheet's total shows.
    var weekTotal: Double { days.suffix(7).map(\.build).reduce(0, +) }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let top = max(values.max() ?? 0, 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: values.count > 1 ? g.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                                     y: g.size.height * (1 - CGFloat(v / top)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 70, height: 18)
        .accessibilityLabel(L("Build costs, last 7 days", "Build-Kosten, letzte 7 Tage"))
        .accessibilityValue(values.map { $0.formatted(.currency(code: "USD")) }.joined(separator: ", "))
    }
}

/// One dot per project that has a budget: green, yellow, red. The budgets live in the app's defaults.
enum ProjectBudgets {
    static let key = "projectBudgets"
    static func all() -> [String: Double] { (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:] }
    static func set(_ name: String, _ value: Double) {
        var d = all()
        if value > 0, value.isFinite { d[name] = value } else { d.removeValue(forKey: name) }
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct ProjectBudgetEditor: View {
    let name: String
    @State private var value = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Monthly budget for this project (0 = none)", "Monatsbudget für dieses Projekt (0 = keins)")).font(.caption)
            TextField("0", value: $value, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                .frame(width: 140).onSubmit { ProjectBudgets.set(name, value) }
            Button(L("Save", "Sichern")) { ProjectBudgets.set(name, value) }
        }
        .padding(12).onAppear { value = ProjectBudgets.all()[name] ?? 0 }
    }
}
