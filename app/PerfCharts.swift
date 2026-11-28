// Deploy Center — Charts in the performance panel: four gauges (memory, load per core, swap, free disk) coloured by
// the guard's own limits, the last 60 minutes from the agent's perf/history.jsonl (lib/perf.sh, one line a minute,
// 24 hours kept), and the biggest consumers as bars. Read-only, Swift Charts from the SDK.

import Charts
import SwiftUI

/// One minute of perf/history.jsonl.
struct PerfHistoryPoint: Decodable, Identifiable {
    let t: Int
    let lvl: String?
    let lpc: Double?
    let swap: Int?
    let free: Double?
    let checks: Int?
    let disk: Double?
    var id: Int { t }
    var date: Date { Date(timeIntervalSince1970: Double(t)) }
}

@MainActor
enum PerfHistory {
    static var file: URL { PerfMonitor.agentFile.deletingLastPathComponent().appendingPathComponent("history.jsonl") }

    /// The points of the last <minutes> minutes (the file's tail is enough: one line a minute).
    static func load(minutes: Int = 60, file: URL? = nil, now: Date = Date()) -> [PerfHistoryPoint] {
        let file = file ?? PerfHistory.file
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let cut = Int(now.timeIntervalSince1970) - minutes * 60
        let dec = JSONDecoder()
        return text.split(separator: "\n").suffix(minutes * 2).compactMap { line in
            try? dec.decode(PerfHistoryPoint.self, from: Data(line.utf8))
        }.filter { $0.t >= cut }
    }
}

enum PerfTone {
    case green, yellow, red
    var color: Color { self == .green ? .green : (self == .yellow ? .orange : .red) }
    var text: String { self == .green ? L("OK", "OK") : (self == .yellow ? L("busy", "knapp") : L("full", "voll")) }
}

/// The four gauges in one row.
struct PerfGauges: View {
    let s: PerfStatus

    private var tiles: [(String, Double, String, PerfTone)] {
        var out: [(String, Double, String, PerfTone)] = []
        let lim = s.limits
        if let free = s.memory?.freePct {
            let p = s.pressure?.level ?? 1
            out.append((L("Memory", "Speicher"), (100 - free) / 100, "\(Int(100 - free)) %", p >= 4 ? .red : (p >= 2 || (s.memoryTight ?? false) ? .yellow : .green)))
        }
        let maxL = lim?.maxLoadPerCore ?? 1, redL = lim?.redLoadPerCore ?? 4
        out.append((L("Load/core", "Last/Kern"), min(1, s.load.perCore / redL), String(format: "%.1f", s.load.perCore),
                    s.load.perCore >= redL ? .red : (s.load.perCore >= maxL ? .yellow : .green)))
        let total = Double(s.swap.totalMB ?? max(1, s.swap.usedMB + (s.swap.freeMB ?? 0)))
        let maxS = Double(lim?.maxSwapUsedMB ?? 3072)
        out.append((L("Swap", "Swap"), total > 0 ? min(1, Double(s.swap.usedMB) / total) : 0, PerfText.gb(s.swap.usedMB),
                    (s.swap.freeMB ?? 1) < 256 ? .red : (Double(s.swap.usedMB) >= maxS ? .yellow : .green)))
        if let d = s.disk?.freeGB {
            let minD = Double(lim?.minFreeDiskGB ?? 100)
            out.append((L("Disk free", "Platte frei"), min(1, d / max(1, minD * 3)), String(format: "%.0f GB", d),
                        d < minD / 2 ? .red : (d < minD ? .yellow : .green)))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tiles, id: \.0) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.0).font(.caption2).foregroundStyle(.secondary)
                    Text(t.2).font(.callout.monospacedDigit().weight(.semibold))
                    Gauge(value: t.1) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).tint(t.3.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(t.0): \(t.2), \(t.3.text)")
            }
        }
    }
}

/// The last 60 minutes, four small line charts with the limits as dashed lines.
struct PerfHistoryCharts: View {
    let s: PerfStatus
    @State private var points: [PerfHistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Last 60 minutes", "Letzte 60 Minuten")).font(.subheadline.weight(.semibold))
            if points.count < 2 {
                Text(L("The history fills in once the agent runs (deploys perf install --yes).",
                       "Der Verlauf füllt sich, sobald der Agent läuft (deploys perf install --yes)."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        mini(L("Load per core", "Last pro Kern"), \.lpc, limit: s.limits?.maxLoadPerCore ?? 1, .blue)
                        mini(L("Swap GB", "Swap GB"), { $0.swap.map { Double($0) / 1024 } }, limit: Double(s.limits?.maxSwapUsedMB ?? 3072) / 1024, .purple)
                    }
                    GridRow {
                        mini(L("Free memory %", "Freier Speicher %"), \.free, limit: nil, .green)
                        mini(L("Heavy checks", "Schwere Checks"), { $0.checks.map(Double.init) }, limit: Double(s.checks.cap), .orange)
                    }
                }
            }
        }
        .task(id: s.time) { points = PerfHistory.load() }
    }

    private func mini(_ title: String, _ value: @escaping (PerfHistoryPoint) -> Double?, limit: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { p in
                    if let v = value(p) { LineMark(x: .value("t", p.date), y: .value(title, v)).foregroundStyle(color).interpolationMethod(.monotone) }
                }
                if let l = limit {
                    RuleMark(y: .value(L("Limit", "Grenze"), l)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(.system(size: 8)) } }
            .frame(height: 46)
        }
    }

    private func mini(_ title: String, _ key: KeyPath<PerfHistoryPoint, Double?>, limit: Double?, _ color: Color) -> some View {
        mini(title, { $0[keyPath: key] }, limit: limit, color)
    }
}

/// The biggest consumers as horizontal bars (GB).
struct PerfConsumerBars: View {
    let s: PerfStatus
    var body: some View {
        let groups = Array(s.groups.filter { $0.key != "other" }.prefix(5))
        Chart(groups, id: \.key) { g in
            BarMark(x: .value("GB", Double(g.mb) / 1024), y: .value(L("Group", "Gruppe"), "\(g.label) (\(g.count))"))
                .foregroundStyle(Color.accentColor.gradient)
                .annotation(position: .trailing) { Text(PerfText.gb(g.mb)).font(.caption2).foregroundStyle(.secondary) }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
        .frame(height: CGFloat(max(1, groups.count)) * 22)
    }
}
