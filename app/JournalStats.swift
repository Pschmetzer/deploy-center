// Deploy Center — figures from the journal alone (this Mac's deploys): when deploys happen and
// fail (FEA-004/162), the costliest failures (FEA-005), the share of clean deploys (FEA-100),
// DORA-style figures (FEA-158), duration trends (FEA-095), two periods side by side (FEA-161),
// and Markdown for notes, a monthly report and a postmortem (FEA-150/163/164).

import SwiftUI

enum JournalStats {
    /// Deploys that went somewhere: a live deploy, a forced one, a failure, a rollback.
    nonisolated static func outcomes(_ list: [JournalEntry]) -> [JournalEntry] {
        list.filter { [.live, .forced, .failed, .rollback].contains($0.kind) }
    }

    /// Counts by weekday (1 = Sunday, Calendar's numbering) and hour: [weekday][hour] = (all, failed).
    nonisolated static func grid(_ list: [JournalEntry], calendar: Calendar = .current) -> [Int: [Int: (all: Int, failed: Int)]] {
        var g: [Int: [Int: (all: Int, failed: Int)]] = [:]
        for e in outcomes(list) {
            let c = calendar.dateComponents([.weekday, .hour], from: e.at)
            guard let w = c.weekday, let h = c.hour else { continue }
            let old = g[w]?[h] ?? (0, 0)
            g[w, default: [:]][h] = (old.all + 1, old.failed + (e.kind == .failed ? 1 : 0))
        }
        return g
    }

    /// The share of good deploys (live or forced) among all that went somewhere; nil with none.
    nonisolated static func cleanShare(_ list: [JournalEntry]) -> Double? {
        let o = outcomes(list)
        guard !o.isEmpty else { return nil }
        return Double(o.filter { $0.kind == .live || $0.kind == .forced }.count) / Double(o.count)
    }

    struct Dora: Equatable {
        /// Good deploys a week, over the span given.
        let perWeek: Double
        /// Failed or rolled back, of all that went somewhere.
        let failRate: Double?
        /// From a failure to the next good deploy of the same project, median, in seconds.
        let restoreMedian: Double?
    }
    nonisolated static func dora(_ list: [JournalEntry], days: Int) -> Dora {
        let o = outcomes(list).sorted { $0.at < $1.at }
        let good = o.filter { $0.kind == .live || $0.kind == .forced }.count
        let bad = o.filter { $0.kind == .failed || $0.kind == .rollback }.count
        var restore: [Double] = []
        var openFail: [String: Date] = [:]
        for e in o {
            let k = "\(e.platform)/\(e.name)"
            if e.kind == .failed || e.kind == .rollback { if openFail[k] == nil { openFail[k] = e.at } }
            else if let f = openFail.removeValue(forKey: k) { restore.append(e.at.timeIntervalSince(f)) }
        }
        return Dora(perWeek: days > 0 ? Double(good) / Double(days) * 7 : 0,
                    failRate: o.isEmpty ? nil : Double(bad) / Double(o.count),
                    restoreMedian: median(restore))
    }

    nonisolated static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Per project: the median build time of the last 5 good deploys against the 5 before.
    /// Only projects with both; slower first.
    struct Trend: Equatable { let key: String; let name: String; let recent: Double; let before: Double }
    nonisolated static func trends(_ list: [JournalEntry]) -> [Trend] {
        var by: [String: [JournalEntry]] = [:]
        for e in list where e.kind == .live && (e.seconds ?? 0) > 0 { by["\(e.platform)/\(e.name)", default: []].append(e) }
        return by.compactMap { k, es in
            let s = es.sorted { $0.at < $1.at }.compactMap(\.seconds)
            guard s.count >= 6 else { return nil }
            let recent = Array(s.suffix(5)), before = Array(s.dropLast(5).suffix(5))
            guard let r = median(recent), let b = median(before), b > 0 else { return nil }
            return Trend(key: k, name: es[0].name, recent: r, before: b)
        }.sorted { $0.recent / $0.before > $1.recent / $1.before }
    }

    /// Failed builds by what they cost (failed × an average build), dearest first. Projects whose
    /// price per build is unknown are left out.
    nonisolated static func costlyFailures(_ list: [JournalEntry], perBuild: (String) -> Double?) -> [(name: String, failed: Int, usd: Double)] {
        var n: [String: Int] = [:]
        for e in list where e.kind == .failed && e.platform.lowercased() == "vercel" { n[e.name, default: 0] += 1 }
        return n.compactMap { name, c in perBuild(name).map { (name, c, Double(c) * $0) } }.sorted { $0.usd > $1.usd }
    }

    /// The failures' reasons, alike ones together (FEA-174): the first line of the detail with numbers
    /// and ids as "#", most often first. Shown with the projects they hit.
    nonisolated static func failureCauses(_ list: [JournalEntry]) -> [(cause: String, count: Int, projects: [String])] {
        var n: [String: (count: Int, projects: [String])] = [:]
        for e in list where e.kind == .failed {
            guard let c = cause(e.detail) else { continue }
            var v = n[c] ?? (0, [])
            v.count += 1; if !v.projects.contains(e.name) { v.projects.append(e.name) }
            n[c] = v
        }
        return n.map { ($0.key, $0.value.count, $0.value.projects) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.cause < $1.cause }
    }
    nonisolated static func cause(_ detail: String?) -> String? {
        guard let line = detail?.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        // "dpl_8f3k2…", "a1b2c3d", "42": what differs from one failure to the next.
        let t = line.replacingOccurrences(of: #"\b(?=[0-9a-zA-Z_-]*[0-9])[0-9a-zA-Z_-]{2,}\b|\b[0-9]\b"#, with: "#", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? nil : String(t.prefix(120))
    }

    /// Entries in [now - days, now) and the same span before it.
    nonisolated static func periods(_ list: [JournalEntry], days: Int, now: Date = Date()) -> (recent: [JournalEntry], before: [JournalEntry]) {
        let span = Double(days) * 86400
        let a = now.addingTimeInterval(-span), b = a.addingTimeInterval(-span)
        return (list.filter { $0.at >= a && $0.at < now }, list.filter { $0.at >= b && $0.at < a })
    }

    /// One line for a notification: what ended in the span. Nil when nothing did.
    nonisolated static func summaryLine(_ list: [JournalEntry]) -> String? {
        let o = outcomes(list)
        guard !o.isEmpty else { return nil }
        let failed = o.filter { $0.kind == .failed }.count, back = o.filter { $0.kind == .rollback }.count
        var parts = [L("\(o.count) deploys", "\(o.count) Deploys"), L("\(failed) failed", "\(failed) fehlgeschlagen")]
        if back > 0 { parts.append(L("\(back) rolled back", "\(back) zurückgerollt")) }
        let slow = o.compactMap { e in e.seconds.map { (e.name, $0) } }.max { $0.1 < $1.1 }
        if let slow, slow.1 >= 60 { parts.append(L("slowest \(Demo.mask(slow.0)) \(Int(slow.1) / 60) min", "am längsten \(Demo.mask(slow.0)) \(Int(slow.1) / 60) min")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Markdown

    /// The entries as a Markdown table (Notion, Obsidian), oldest first.
    nonisolated static func markdown(_ list: [JournalEntry], mask: (String) -> String = { $0 }) -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        let head = "| " + [L("Time", "Zeit"), L("Platform", "Plattform"), L("Project", "Projekt"), L("Result", "Ergebnis"), L("Seconds", "Sekunden"), L("Detail", "Detail")].joined(separator: " | ") + " |\n|---|---|---|---|---|---|"
        return ([head] + list.map { e in
            "| " + [e.at.formatted(.iso8601), e.platform, cell(mask(e.name)), e.kind.title, e.seconds.map { String(Int($0)) } ?? "", cell(e.detail ?? "")].joined(separator: " | ") + " |"
        }).joined(separator: "\n")
    }

    /// A month in a few lines: counts, the clean share, the slowest and most failing projects.
    nonisolated static func monthReport(_ list: [JournalEntry], month: Date = Date(), calendar: Calendar = .current, mask: (String) -> String = { $0 }) -> String {
        let mine = list.filter { calendar.isDate($0.at, equalTo: month, toGranularity: .month) }
        let o = outcomes(mine)
        let title = month.formatted(.dateTime.month(.wide).year())
        var lines = ["# " + L("Deploys in \(title)", "Deploys im \(title)"), ""]
        lines.append("- " + L("Deploys: \(o.count)", "Deploys: \(o.count)"))
        lines.append("- " + L("Failed: \(o.filter { $0.kind == .failed }.count)", "Fehlgeschlagen: \(o.filter { $0.kind == .failed }.count)"))
        lines.append("- " + L("Rolled back: \(o.filter { $0.kind == .rollback }.count)", "Zurückgerollt: \(o.filter { $0.kind == .rollback }.count)"))
        if let c = cleanShare(mine) { lines.append("- " + L("Clean: \(Int((c * 100).rounded())) %", "Sauber: \(Int((c * 100).rounded())) %")) }
        let fails = Dictionary(grouping: o.filter { $0.kind == .failed }, by: \.name).mapValues(\.count).sorted { $0.value > $1.value }.prefix(3)
        if !fails.isEmpty {
            lines += ["", "## " + L("Most failures", "Die meisten Fehlschläge")]
            lines += fails.map { "- \(mask($0.key)): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }

    /// A postmortem to fill in, from a failed or rolled-back entry.
    nonisolated static func postmortem(_ e: JournalEntry, mask: (String) -> String = { $0 }) -> String {
        [ "# " + L("Postmortem: \(mask(e.name))", "Postmortem: \(mask(e.name))"), "",
          "- " + L("When", "Wann") + ": " + e.at.formatted(date: .long, time: .shortened),
          "- " + L("Platform", "Plattform") + ": " + e.platform,
          "- " + L("Result", "Ergebnis") + ": " + e.kind.title,
          e.detail.map { "- " + L("Detail", "Detail") + ": " + $0 } ?? nil,
          "", "## " + L("What happened", "Was ist passiert"), "",
          "## " + L("Impact", "Auswirkung"), "",
          "## " + L("Cause", "Ursache"), "",
          "## " + L("What we change", "Was wir ändern"), ""
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

/// The figures above, in the history window.
struct JournalStatsView: View {
    let entries: [JournalEntry]
    var costs: Costs?
    @State private var days = 30

    private var period: (recent: [JournalEntry], before: [JournalEntry]) { JournalStats.periods(entries, days: days) }

    var body: some View {
        let p = period
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker(L("Period", "Zeitraum"), selection: $days) {
                    Text(L("7 days", "7 Tage")).tag(7); Text(L("30 days", "30 Tage")).tag(30); Text(L("90 days", "90 Tage")).tag(90)
                }.pickerStyle(.segmented).frame(width: 280)
                figures(p)
                Text(L("From this Mac's history only; lead time from commit to live needs GitHub and is not counted.",
                       "Nur aus dem Verlauf dieses Macs; die Zeit vom Commit bis live braucht GitHub und fehlt."))
                    .font(.caption).foregroundStyle(.secondary)
                heat(p.recent)
                lists(p.recent)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// In parts of their own: as one body it was too long for the type checker on CI.
    @ViewBuilder private func figures(_ p: (recent: [JournalEntry], before: [JournalEntry])) -> some View {
        let d = JournalStats.dora(p.recent, days: days), db = JournalStats.dora(p.before, days: days)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text(""); Text(L("Now", "Jetzt")).bold(); Text(L("The \(days) days before", "Die \(days) Tage davor")).foregroundStyle(.secondary)
            }
            GridRow { Text(L("Deploys a week", "Deploys pro Woche")); Text(fmt(d.perWeek)); Text(fmt(db.perWeek)).foregroundStyle(.secondary) }
            GridRow { Text(L("Clean deploys", "Saubere Deploys")); Text(pct(JournalStats.cleanShare(p.recent))); Text(pct(JournalStats.cleanShare(p.before))).foregroundStyle(.secondary) }
            GridRow { Text(L("Failed or rolled back", "Fehlgeschlagen oder zurückgerollt")); Text(pct(d.failRate)); Text(pct(db.failRate)).foregroundStyle(.secondary) }
            GridRow { Text(L("Back to good (median)", "Wieder gut (Median)")); Text(dur(d.restoreMedian)); Text(dur(db.restoreMedian)).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func lists(_ recent: [JournalEntry]) -> some View {
        let t = JournalStats.trends(entries).filter { $0.recent > $0.before * 1.2 }.prefix(5)
        if !t.isEmpty {
            Text(L("Builds getting slower", "Builds werden langsamer")).font(.headline)
            ForEach(Array(t), id: \.key) { r in
                Text("\(Demo.mask(r.name)): \(dur(r.before)) → \(dur(r.recent))").font(.callout)
            }
        }
        let causes = JournalStats.failureCauses(recent).prefix(5)
        if !causes.isEmpty {
            Text(L("Why builds failed", "Warum Builds fehlschlugen")).font(.headline)
            ForEach(Array(causes), id: \.cause) { r in
                Text(causeLine(count: r.count, cause: r.cause, projects: r.projects)).font(.callout).lineLimit(2).textSelection(.enabled)
            }
        }
        if let c = costs {
            let f = JournalStats.costlyFailures(recent, perBuild: c.perBuild).prefix(5)
            if !f.isEmpty {
                Text(L("Costliest failures", "Teuerste Fehlschläge")).font(.headline)
                ForEach(Array(f), id: \.name) { r in
                    Text(L("\(Demo.mask(r.name)): \(r.failed) failed, about $\(String(format: "%.2f", r.usd))",
                           "\(Demo.mask(r.name)): \(r.failed) fehlgeschlagen, etwa \(String(format: "%.2f", r.usd)) $")).font(.callout)
                }
            }
        }
    }

    private func causeLine(count: Int, cause: String, projects: [String]) -> String {
        let stand: [Item] = Set(entries.map(\.name)).map { Item(id: $0, name: $0, detail: "", platform: .vercel, deployable: false, auto: false, note: nil, link: nil) }
        let names: String = projects.prefix(3).map(Demo.mask).joined(separator: ", ") + (projects.count > 3 ? " …" : "")
        return "\(count)× " + Demo.scrub(cause, items: stand) + " – " + names
    }

    /// Weekday × time of day (four blocks of six hours), darker = more deploys, red = failures.
    @ViewBuilder private func heat(_ list: [JournalEntry]) -> some View {
        let g = JournalStats.grid(list)
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        let cells = order.map { w in (0..<4).map { b in (b * 6..<b * 6 + 6).reduce((0, 0)) { a, h in let v = g[w]?[h] ?? (0, 0); return (a.0 + v.all, a.1 + v.failed) } } }
        let top = max(1, cells.flatMap { $0.map(\.0) }.max() ?? 1)
        Text(L("When deploys happen", "Wann deployt wird")).font(.headline)
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(["0–6", "6–12", "12–18", "18–24"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(Array(order.enumerated()), id: \.offset) { i, w in
                GridRow {
                    Text(cal.shortWeekdaySymbols[w - 1]).font(.caption)
                    ForEach(0..<4, id: \.self) { b in
                        let (n, f) = cells[i][b]
                        RoundedRectangle(cornerRadius: 3)
                            .fill((f > 0 ? Color.red : Color.accentColor).opacity(n == 0 ? 0.06 : 0.2 + 0.8 * Double(n) / Double(top)))
                            .frame(width: 56, height: 18)
                            .overlay(Text(n == 0 ? "" : "\(n)").font(.caption2.monospacedDigit()))
                            .help(L("\(n) deploys, \(f) failed", "\(n) Deploys, \(f) fehlgeschlagen"))
                            .accessibilityLabel(cal.weekdaySymbols[w - 1] + ": " + L("\(n) deploys, \(f) failed", "\(n) Deploys, \(f) fehlgeschlagen"))
                    }
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
    private func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded())) %" } ?? "–" }
    private func dur(_ s: Double?) -> String {
        guard let s else { return "–" }
        if s < 3600 { return "\(Int(s) / 60):\(String(format: "%02d", Int(s) % 60))" }
        return String(format: "%.1f h", s / 3600)
    }
}
