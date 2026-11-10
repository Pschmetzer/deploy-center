// Deploy Center — Widgets: what waits, what builds, what failed, and the saving.
// Reads the snapshot the app writes to the App Group container; never calls a network.
// The Mac app (build.sh --widgets) and the iOS app (Xcode) both build this file.

import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snap: DeploySnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // The gallery shows made-up numbers until the app has written a snapshot.
        completion(Entry(date: Date(), snap: DeploySnapshot.read() ?? (context.isPreview ? .sample : nil)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a reload after each change; this is only the fallback. A second entry once
        // the snapshot is three hours old, so "out of date" shows without the app.
        let snap = DeploySnapshot.read(), now = Date()
        var entries = [Entry(date: now, snap: snap)]
        if let s = snap, s.at.addingTimeInterval(Words.staleAfter) > now { entries.append(Entry(date: s.at.addingTimeInterval(Words.staleAfter), snap: s)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

/// The words in the app's language: the one the snapshot names (Mac: Settings → Language; iPhone: the
/// app's language), read once per entry; without one, the system's.
struct Words {
    let german: Bool
    init(_ snap: DeploySnapshot?) {
        german = (snap?.language ?? Locale.preferredLanguages.first ?? "en").hasPrefix("de")
    }
    func callAsFunction(_ en: String, _ de: String) -> String { german ? de : en }
    func n(_ n: Int, _ one: (String, String), _ many: (String, String)) -> String {
        "\(n) " + (n == 1 ? self(one.0, one.1) : self(many.0, many.1))
    }
    /// After this long without a new snapshot the numbers are greyed and marked as old.
    static let staleAfter: TimeInterval = 3 * 3600
}

private struct WordsKey: EnvironmentKey { static let defaultValue = Words(nil) }
extension EnvironmentValues {
    var words: Words { get { self[WordsKey.self] } set { self[WordsKey.self] = newValue } }
}

private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

/// A link that shows one project in the app: deploycenter://select?project=…&platform=… (Mac and iPhone).
private func link(_ p: DeploySnapshot.Project) -> URL {
    var c = URLComponents(); c.scheme = "deploycenter"; c.host = "select"
    c.queryItems = [URLQueryItem(name: "project", value: p.name), URLQueryItem(name: "platform", value: p.platform)]
    return c.url ?? URL(string: "deploycenter://")!
}

extension DeploySnapshot {
    func isStale(at date: Date) -> Bool { date.timeIntervalSince(at) > Words.staleAfter }
    /// One sentence for VoiceOver: "5 PRs waiting in 3 projects, 1 building, 1 failed."
    func spoken(_ w: Words) -> String {
        var s = w("\(w.n(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(w.n(waitingProjects, ("project", "Projekt"), ("projects", "Projekten")))",
                  "\(w.n(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) \(waitingPRs == 1 ? "wartet" : "warten") in \(w.n(waitingProjects, ("project", "Projekt"), ("projects", "Projekten")))")
        if building > 0 { s += w(", \(building) building", ", \(building) im Bau") }
        if failed > 0 { s += w(", \(failed) failed", ", \(failed) fehlgeschlagen") }
        return s + "."
    }
}

/// "Deploy Center", "Demo", and the time of the snapshot (orange once it is old).
struct Header: View {
    let snap: DeploySnapshot
    let date: Date
    var compact = false
    @Environment(\.words) private var w
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill").accessibilityLabel("Deploy Center")
            if !compact { Text("Deploy Center").lineLimit(1) }
            if snap.demo { Text("Demo").padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
            Spacer(minLength: 2)
            Text(snap.isStale(at: date) ? w("old: ", "alt: ") + snap.at.formatted(date: .omitted, time: .shortened)
                                         : snap.at.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(snap.isStale(at: date) ? Color.orange : .secondary)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct BigNumber: View {
    let snap: DeploySnapshot
    let date: Date
    /// Grows with Dynamic Type.
    @ScaledMetric private var size: CGFloat
    init(snap: DeploySnapshot, date: Date, size: CGFloat) {
        self.snap = snap; self.date = date
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }
    var body: some View {
        Text("\(snap.waitingPRs)").font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(snap.waitingPRs > 0 && !snap.isStale(at: date) ? Color.accentColor : .secondary)
            .widgetAccentable()
            .minimumScaleFactor(0.6).lineLimit(1)
            .contentTransition(.numericText())
    }
}

struct SmallView: View {
    let snap: DeploySnapshot
    let date: Date
    @Environment(\.words) private var w
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(snap: snap, date: date, compact: true)
            Spacer(minLength: 0)
            BigNumber(snap: snap, date: date, size: 44)
            Text(snap.waitingPRs == 1 ? w("PR waiting", "PR wartet") : w("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
            Text(w.n(snap.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))).font(.caption2).foregroundStyle(.secondary)
            StatusLine(snap: snap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snap.spoken(w))
    }
}

struct StatusLine: View {
    let snap: DeploySnapshot
    var body: some View {
        HStack(spacing: 8) {
            if snap.building > 0 { Label("\(snap.building)", systemImage: "hammer.fill").foregroundStyle(.blue) }
            if snap.failed > 0 { Label("\(snap.failed)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
        .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
        .widgetAccentable()
    }
}

/// Medium (three rows), large (six) and extra large (ten, iPad and Mac).
struct ListView: View {
    let snap: DeploySnapshot
    let date: Date
    let rows: Int
    @Environment(\.words) private var w
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Header(snap: snap, date: date, compact: true)
                Spacer(minLength: 0)
                BigNumber(snap: snap, date: date, size: 36)
                Text(snap.waitingPRs == 1 ? w("PR waiting", "PR wartet") : w("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
                Text(w.n(snap.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))).font(.caption2).foregroundStyle(.secondary)
                if let s = snap.saving, s.after < s.before {
                    Text(w("≈ \(money(s.month))/mo saved", "≈ \(money(s.month))/Monat gespart"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
            }
            .frame(width: 104, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snap.spoken(w))
            VStack(alignment: .leading, spacing: 7) {
                if snap.projects.isEmpty {
                    Spacer()
                    Text(w("Nothing waits.", "Nichts wartet.")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(snap.projects.prefix(rows)) { p in Link(destination: link(p)) { ProjectRow(p: p) } }
                    if snap.projects.count > rows {
                        Text(w("+\(snap.projects.count - rows) more", "+\(snap.projects.count - rows) weitere")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ProjectRow: View {
    let p: DeploySnapshot.Project
    @Environment(\.words) private var w
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: 14).widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                // Names and commit lines are hidden on a locked device's lock screen; the counts are not.
                Text(p.name).font(.caption.weight(.semibold)).lineLimit(1).privacySensitive()
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch p.status { case .building: "hammer.fill"; case .failed: "xmark.octagon.fill"; case .waiting: "arrow.up.circle.fill" }
    }
    private var tint: Color {
        switch p.status { case .building: .blue; case .failed: .red; case .waiting: .accentColor }
    }
    private var detail: String {
        switch p.status {
        case .building: return w("building · \(p.platform)", "baut · \(p.platform)")
        case .failed: return w("failed · \(p.platform)", "fehlgeschlagen · \(p.platform)")
        case .waiting:
            let prs = p.prs > 0 ? w.n(p.prs, ("PR", "PR"), ("PRs", "PRs")) + " · " : ""
            return prs + w.n(p.commits, ("commit", "Commit"), ("commits", "Commits")) + " · \(p.platform)"
        }
    }
}

struct NoSnapshotView: View {
    var notConnected = false
    @Environment(\.words) private var w
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Deploy Center", systemImage: "paperplane.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(notConnected ? w("Connect Deploy Center to your accounts to fill this widget.", "Verbinde Deploy Center mit deinen Konten, um dieses Widget zu füllen.")
                              : w("Open Deploy Center once to fill this widget.", "Öffne Deploy Center einmal, um dieses Widget zu füllen."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

#if os(iOS)
/// Lock screen and StandBy: the number, the worst state, one line.
struct AccessoryView: View {
    let snap: DeploySnapshot?
    let date: Date
    @Environment(\.widgetFamily) var family
    @Environment(\.words) private var w
    var body: some View {
        if let s = snap, s.connected != false {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: worst(s)).font(.caption2)
                        Text("\(s.waitingPRs)").font(.title3.weight(.bold).monospacedDigit()).minimumScaleFactor(0.6)
                    }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(s.spoken(w))
            case .accessoryInline:
                Label(w("\(w.n(s.waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) waiting", "\(w.n(s.waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) \(s.waitingPRs == 1 ? "wartet" : "warten")")
                      + (s.failed > 0 ? w(" · \(s.failed) failed", " · \(s.failed) Fehler") : ""), systemImage: worst(s))
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Label(w("\(s.waitingPRs) waiting", "\(s.waitingPRs) wartend"), systemImage: "paperplane.fill").font(.headline).widgetAccentable()
                    Text(w.n(s.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))
                         + (s.building > 0 ? w(" · \(s.building) building", " · \(s.building) im Bau") : "")
                         + (s.failed > 0 ? w(" · \(s.failed) failed", " · \(s.failed) Fehler") : ""))
                        .font(.caption)
                    if let p = s.projects.first { Text(p.name).font(.caption2).lineLimit(1).privacySensitive() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore).accessibilityLabel(s.spoken(w))
            }
        } else {
            Image(systemName: "paperplane").accessibilityLabel("Deploy Center")
        }
    }
    private func worst(_ s: DeploySnapshot) -> String {
        s.failed > 0 ? "xmark.octagon.fill" : s.building > 0 ? "hammer.fill" : s.waitingPRs > 0 ? "arrow.up.circle.fill" : "checkmark.circle.fill"
    }
}
#endif

struct DeployWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            #if os(iOS)
            if [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family) {
                AccessoryView(snap: entry.snap, date: entry.date)
            } else { system }
            #else
            system
            #endif
        }
        .environment(\.words, Words(entry.snap))
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "deploycenter://"))
    }

    @ViewBuilder private var system: some View {
        if let s = entry.snap, s.connected != false {
            switch family {
            case .systemSmall: SmallView(snap: s, date: entry.date)
            case .systemLarge: ListView(snap: s, date: entry.date, rows: 6)
            case .systemExtraLarge: ListView(snap: s, date: entry.date, rows: 10)
            default: ListView(snap: s, date: entry.date, rows: 3)
            }
        } else { NoSnapshotView(notConnected: entry.snap?.connected == false) }
    }
}

struct DeployWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeploySnapshot.widgetKind, provider: Provider()) { DeployWidgetView(entry: $0) }
            .configurationDisplayName("Deploy Center")
            .description(Words(DeploySnapshot.read())("Waiting pull requests, builds, failures and the saving.",
                                                      "Wartende Pull Requests, Builds, Fehler und die Ersparnis."))
            .supportedFamilies(Self.families)
    }
    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

@main
struct DeployWidgets: WidgetBundle {
    var body: some Widget { DeployWidget() }
}
