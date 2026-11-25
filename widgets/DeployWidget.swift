// Deploy Center — Widgets: what waits, what builds, what failed, and the saving.
// Reads the snapshot the app writes to the App Group container; never calls a network.
// The Mac app (build.sh --widgets) and the iOS app (Xcode) both build this file.

import SwiftUI
import WidgetKit
#if os(iOS)
import ActivityKit
import AppIntents
#endif

struct Entry: TimelineEntry {
    let date: Date
    let snap: DeploySnapshot?
    /// Why there is no snapshot (no file yet, unreadable, written by a newer app).
    var problem: DeploySnapshot.ReadProblem? = nil
    /// A failed build is what the person most wants to see; a build that runs long or a project that waits
    /// over a day rises less (the snapshot decides, see relevanceScore).
    var relevance: TimelineEntryRelevance? {
        guard let s = snap, let score = s.relevanceScore(at: date) else { return nil }
        return TimelineEntryRelevance(score: score)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // The gallery shows made-up numbers until the app has written a snapshot.
        let r = DeploySnapshot.readOutcome()
        completion(Entry(date: Date(), snap: r.snapshot ?? (context.isPreview ? .sample : nil), problem: r.problem))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a reload after each change; this is only the fallback. A second entry once
        // the snapshot is three hours old, so "out of date" shows without the app (iOS only, see isStale).
        let r = DeploySnapshot.readOutcome(), snap = r.snapshot, now = Date()
        var entries = [Entry(date: now, snap: snap, problem: r.problem)]
        if let s = snap, let d = WidgetRefresh.staleEntryDate(snapshotAt: s.at, now: now) { entries.append(Entry(date: d, snap: s)) }
        completion(Timeline(entries: entries, policy: .after(WidgetRefresh.nextReload(snapshotAt: snap?.at, building: snap?.building ?? 0, now: now))))
    }
}

private struct WordsKey: EnvironmentKey { static let defaultValue = Words(nil) }
extension EnvironmentValues {
    var words: Words { get { self[WordsKey.self] } set { self[WordsKey.self] = newValue } }
}

private func money(_ v: Double, _ w: Words) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0)).locale(w.locale)) }

/// Orange for small text: the system orange is about 2.3:1 on white; this one reaches 4.5:1 in light mode
/// (the app's `warningText`), and is the system orange in dark mode. `warn` false gives `other`.
private struct WarnText<S: ShapeStyle>: ViewModifier {
    let warn: Bool
    let other: S
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if warn { content.foregroundStyle(scheme == .dark ? Color.orange : Color(red: 0.62, green: 0.30, blue: 0)) }
        else { content.foregroundStyle(other) }
    }
}
private extension View {
    func warnText<S: ShapeStyle>(_ warn: Bool = true, otherwise other: S = Color.secondary) -> some View { modifier(WarnText(warn: warn, other: other)) }
}

/// A link that shows one project in the app: deploycenter://select?project=…&platform=… (Mac and iPhone).
private func link(_ p: DeploySnapshot.Project) -> URL {
    var c = URLComponents(); c.scheme = "deploycenter"; c.host = "select"
    c.queryItems = [URLQueryItem(name: "project", value: p.name), URLQueryItem(name: "platform", value: p.platform)]
    // The provider's own id when the snapshot has it: two projects of one name (two teams) stay apart.
    if let k = p.key { c.queryItems?.append(URLQueryItem(name: "key", value: k)) }
    return c.url ?? URL(string: "deploycenter://")!
}

extension DeploySnapshot {
    /// Only on iOS: there the app is often not running for hours. The Mac app writes the snapshot only
    /// when its content changes, so its time is the last change, not the last look: old there means nothing.
    func isStale(at date: Date) -> Bool {
        #if os(iOS)
        date.timeIntervalSince(at) > Words.staleAfter
        #else
        false
        #endif
    }
    /// One sentence for VoiceOver: "5 PRs waiting in 3 projects, 1 building, 1 failed."
    func spoken(_ w: Words) -> String {
        var s = w("\(w.n(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(w.n(waitingProjects, ("project", "Projekt"), ("projects", "Projekten")))",
                  "\(w.n(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) \(waitingPRs == 1 ? "wartet" : "warten") in \(w.n(waitingProjects, ("project", "Projekt"), ("projects", "Projekten")))")
        if building > 0 { s += w(", \(building) building", ", \(building) im Bau") }
        if failed > 0 { s += w(", \(failed) failed", ", \(failed) fehlgeschlagen") }
        // The "Demo" mark is hidden from VoiceOver with the rest of the header: say it here.
        if demo { s += w(", demo data", ", Demodaten") }
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
            // The time of the data, only on iOS (see isStale): with the day when it is not today.
            #if os(iOS)
            let when = Calendar.current.isDate(snap.at, inSameDayAs: date) ? snap.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(w.locale))
                                                                           : snap.at.formatted(Date.FormatStyle().day().month().hour().minute().locale(w.locale))
            Text(snap.isStale(at: date) ? w("old: ", "alt: ") + when : when)
                .warnText(snap.isStale(at: date))
                .lineLimit(1)
            #endif
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
            .lineLimit(1).minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .foregroundStyle(snap.waitingPRs > 0 && !snap.isStale(at: date) ? Color.accentColor : .secondary)
            .widgetAccentable()
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
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(w.n(snap.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
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

/// Medium (three rows), large (six) and extra large (ten, iPad only: the Mac has no extra-large widget).
struct ListView: View {
    let snap: DeploySnapshot
    let date: Date
    let rows: Int
    @Environment(\.words) private var w
    @ScaledMetric(relativeTo: .caption) private var columnWidth = 104.0
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Header(snap: snap, date: date, compact: true)
                Spacer(minLength: 0)
                BigNumber(snap: snap, date: date, size: 36)
                Text(snap.waitingPRs == 1 ? w("PR waiting", "PR wartet") : w("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(w.n(snap.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let s = snap.saving, s.after < s.before {
                    Text(w("≈ \(money(s.month, w))/mo saved", "≈ \(money(s.month, w))/Monat gespart"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
            }
            // Grows with the text size.
            .frame(minWidth: 0, idealWidth: columnWidth, maxWidth: columnWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snap.spoken(w))
            VStack(alignment: .leading, spacing: 7) {
                if snap.projects.isEmpty {
                    Spacer()
                    Text(w("Nothing waits.", "Nichts wartet.")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(snap.projects.prefix(rows)) { p in Link(destination: link(p)) { ProjectRow(p: p) } }
                    // The snapshot lists at most ten rows: the rest is counted from the totals.
                    let more = snap.waitingProjects + snap.building + snap.failed - min(rows, snap.projects.count)
                    if more > 0 {
                        Text(w("+\(more) more", "+\(more) weitere")).font(.caption2).foregroundStyle(.secondary)
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
    /// The icon column grows with Dynamic Type, so a larger icon does not push into the name.
    @ScaledMetric(relativeTo: .caption) private var iconWidth: CGFloat = 14
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: iconWidth).widgetAccentable().accessibilityHidden(true)
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
            // A waiting row with 0 commits means the count is unknown (e.g. rewritten history).
            if p.commits == 0 { return prs + w("count unknown · \(p.platform)", "Anzahl unbekannt · \(p.platform)") }
            return prs + w.n(p.commits, ("commit", "Commit"), ("commits", "Commits")) + " · \(p.platform)"
        }
    }
}

struct NoSnapshotView: View {
    var notConnected = false
    var problem: DeploySnapshot.ReadProblem? = nil
    @Environment(\.words) private var w
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Deploy Center", systemImage: "paperplane.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(notConnected ? w("Connect Deploy Center to your accounts to fill this widget.", "Verbinde Deploy Center mit deinen Konten, um dieses Widget zu füllen.")
                 : problem == .appNewer ? w("Update Deploy Center: the app is newer than this widget.", "Aktualisiere Deploy Center: Die App ist neuer als dieses Widget.")
                 : problem == .unreadable ? w("The widget could not read its data. Open Deploy Center to write it again.", "Das Widget konnte seine Daten nicht lesen. Öffne Deploy Center, um sie neu zu schreiben.")
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
                      + (s.failed > 0 ? w(" · \(s.failed) failed", " · \(s.failed) fehlgeschlagen") : ""), systemImage: worst(s))
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Label(w("\(s.waitingPRs) waiting", "\(s.waitingPRs) wartend"), systemImage: "paperplane.fill").font(.headline).widgetAccentable()
                    Text(w.n(s.waitingProjects, ("project", "Projekt"), ("projects", "Projekte"))
                         + (s.building > 0 ? w(" · \(s.building) building", " · \(s.building) im Bau") : "")
                         + (s.failed > 0 ? w(" · \(s.failed) failed", " · \(s.failed) fehlgeschlagen") : ""))
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
        } else { NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem) }
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

/// Only what failed or builds, with a tap to open it. Mac and iPhone.
struct ProblemsWidget: Widget {
    static let kind = "DeployCenterProblems"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { ProblemsWidgetView(entry: $0) }
            .configurationDisplayName(Words(DeploySnapshot.read())("Failed deploys", "Fehlgeschlagene Deploys"))
            .description(Words(DeploySnapshot.read())("Only the projects whose deploy failed or still builds.",
                                                      "Nur die Projekte, deren Deploy fehlschlug oder noch baut."))
            .supportedFamilies(Self.families)
    }
    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular]   // the lock screen: the number of failures
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

/// Open outages: the projects whose newest deploy failed and has not been followed by a good one, with how long.
/// It reads the snapshot (`since` of a failed row is when that deploy started) and starts nothing.
struct OutagesWidget: Widget {
    static let kind = "DeployCenterOutages"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { OutagesWidgetView(entry: $0) }
            .configurationDisplayName(Words(DeploySnapshot.read())("Open outages", "Offene Ausfälle"))
            .description(Words(DeploySnapshot.read())("Projects whose newest deploy failed, and since when.",
                                                      "Projekte, deren neuester Deploy fehlschlug, und seit wann."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OutagesWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            if let s = entry.snap, s.connected != false {
                OutagesView(snap: s, date: entry.date, rows: family == .systemLarge ? 6 : family == .systemMedium ? 3 : 2)
            } else {
                NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem)
            }
        }
        .environment(\.words, Words(entry.snap))
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(entry.snap?.projects.first(where: { $0.status == .failed }).map(link) ?? URL(string: "deploycenter://"))
    }
}

struct OutagesView: View {
    let snap: DeploySnapshot
    let date: Date
    let rows: Int
    @Environment(\.words) private var w
    var body: some View {
        let bad = snap.projects.filter { $0.status == .failed }
        VStack(alignment: .leading, spacing: 6) {
            Header(snap: snap, date: date, compact: true)
            if bad.isEmpty && snap.isStale(at: date) {
                Spacer(minLength: 0)
                Label(w("Out of date: open the app", "Veraltet: App öffnen"), systemImage: "clock.badge.exclamationmark")
                    .font(.callout.weight(.medium)).warnText()
                Spacer(minLength: 0)
            } else if bad.isEmpty {
                Spacer(minLength: 0)
                Label(w("No open outages", "Keine offenen Ausfälle"), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green).widgetAccentable()
                Spacer(minLength: 0)
            } else {
                ForEach(bad.prefix(rows)) { p in
                    Link(destination: link(p)) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption).widgetAccentable().accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.name).font(.caption.weight(.semibold)).lineLimit(1).privacySensitive()
                                if let since = p.since {
                                    Text("\(w("since", "seit")) \(since, style: .relative)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text(p.platform).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                let more = snap.failed - min(rows, bad.count)
                if more > 0 { Text(w("+\(more) more", "+\(more) weitere")).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#if os(iOS)
/// Lock screen: only the number of failed deploys (and the first one's name), nothing else.
struct ProblemsAccessoryView: View {
    let snap: DeploySnapshot
    @Environment(\.widgetFamily) var family
    @Environment(\.words) private var w
    var body: some View {
        let n = snap.failed
        let icon = n == 0 ? "checkmark.circle" : "xmark.octagon.fill"
        let spoken = n == 0 ? w("No failed deploys", "Keine fehlgeschlagenen Deploys")
                            : w.n(n, ("failed deploy", "fehlgeschlagener Deploy"), ("failed deploys", "fehlgeschlagene Deploys"))
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(spoken, systemImage: icon).font(.headline).widgetAccentable()
                if let p = snap.projects.first(where: { $0.status == .failed }) { Text(p.name).font(.caption).lineLimit(1).privacySensitive() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: icon).font(.caption2)
                    Text("\(n)").font(.title3.weight(.bold).monospacedDigit()).minimumScaleFactor(0.6)
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
        }
    }
}
#endif

struct ProblemsWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            #if os(iOS)
            if family == .accessoryCircular || family == .accessoryRectangular {
                if let s = entry.snap, s.connected != false { ProblemsAccessoryView(snap: s) }
                else { NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem) }
            } else if let s = entry.snap, s.connected != false { ProblemsView(snap: s, date: entry.date, rows: family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2) }
            else { NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem) }
            #else
            if let s = entry.snap, s.connected != false { ProblemsView(snap: s, date: entry.date, rows: family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2) }
            else { NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem) }
            #endif
        }
        .environment(\.words, Words(entry.snap))
        .containerBackground(.fill.tertiary, for: .widget)
        // A small widget has no Link: the one tap opens the first project that needs a look (the app otherwise).
        .widgetURL(family == .systemSmall ? entry.snap?.projects.first(where: { $0.status != .waiting }).map(link)
                   ?? URL(string: "deploycenter://") : URL(string: "deploycenter://"))
    }
}

struct ProblemsView: View {
    let snap: DeploySnapshot
    let date: Date
    let rows: Int
    @Environment(\.words) private var w
    var body: some View {
        let bad = snap.projects.filter { $0.status != .waiting }
        VStack(alignment: .leading, spacing: 6) {
            Header(snap: snap, date: date, compact: true)
            if bad.isEmpty && snap.isStale(at: date) {
                // An old snapshot cannot say that nothing failed.
                Spacer(minLength: 0)
                Label(w("Out of date: open the app", "Veraltet: App öffnen"), systemImage: "clock.badge.exclamationmark")
                    .font(.callout.weight(.medium)).warnText()
                Spacer(minLength: 0)
            } else if bad.isEmpty {
                Spacer(minLength: 0)
                Label(w("Nothing failed", "Nichts fehlgeschlagen"), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green).widgetAccentable()
                Spacer(minLength: 0)
            } else {
                StatusLine(snap: snap)
                ForEach(bad.prefix(rows)) { p in Link(destination: link(p)) { ProjectRow(p: p) } }
                let more = snap.failed + snap.building - min(rows, bad.count)
                if more > 0 { Text(w("+\(more) more", "+\(more) weitere")).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The next deploy a schedule will start: the name and a live countdown. Only reads the snapshot.
struct NextDeployWidget: Widget {
    static let kind = "DeployCenterNext"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { NextDeployView(entry: $0) }
            .configurationDisplayName(Words(DeploySnapshot.read())("Next scheduled deploy", "Nächster geplanter Deploy"))
            .description(Words(DeploySnapshot.read())("Which project a schedule deploys next, and when.",
                                                      "Welches Projekt ein Zeitplan als Nächstes deployt, und wann."))
            .supportedFamilies(Self.families)
    }
    static var families: [WidgetFamily] {
        [.systemSmall, .systemMedium]
    }
}

struct NextDeployView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            if let s = entry.snap, s.connected != false { NextDeployContent(snap: s, date: entry.date, family: family) }
            else { NoSnapshotView(notConnected: entry.snap?.connected == false, problem: entry.problem) }
        }
        .environment(\.words, Words(entry.snap))
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "deploycenter://"))
    }
}

struct NextDeployContent: View {
    let snap: DeploySnapshot
    let date: Date
    let family: WidgetFamily
    @Environment(\.words) private var w
    var body: some View {
        // An old snapshot cannot say that nothing is planned, and a time in the past is not "next".
        let run = snap.nextScheduled.flatMap { $0.at > date ? $0 : nil }
        let stale = snap.isStale(at: date)
        switch family {
        #if os(iOS)
        case .accessoryInline:
            if let r = run { Label { Text(w("Deploy ", "Deploy ")) + Text(r.at, style: .relative) } icon: { Image(systemName: "clock") } }
            else { Label(stale ? w("Out of date", "Veraltet") : w("No deploy planned", "Kein Deploy geplant"), systemImage: "clock") }
        #endif
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label(w("Next deploy", "Nächster Deploy"), systemImage: "clock.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary).widgetAccentable()
                if let r = run {
                    Text(r.name).font(.headline).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                    Text(r.at, style: .relative).font(.title3.weight(.bold).monospacedDigit()).minimumScaleFactor(0.6)
                    Text((r.platform.isEmpty ? "" : r.platform + " · ") + r.at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(w.locale))).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Spacer(minLength: 0)
                    Text(stale ? w("Out of date: open the app", "Veraltet: App öffnen") : w("No deploy planned", "Kein Deploy geplant"))
                        .font(.callout.weight(.medium)).warnText(stale)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        }
    }
}

#if os(iOS)
/// Which platform the configurable widget shows.
enum WidgetPlatform: String, AppEnum {
    case all, vercel, render
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Platform"
    static let caseDisplayRepresentations: [WidgetPlatform: DisplayRepresentation] = [.all: "All", .vercel: "Vercel", .render: "Render"]
    var name: String? { self == .vercel ? "Vercel" : self == .render ? "Render" : nil }
}

struct FilterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "What to show"
    static let description = IntentDescription("One platform, or only failed deploys.")
    @Parameter(title: "Platform", default: .all) var platform: WidgetPlatform
    @Parameter(title: "Only failed deploys", default: false) var onlyFailed: Bool
}

struct FilteredProvider: AppIntentTimelineProvider {
    private func entry(_ c: FilterIntent, preview: Bool) -> Entry {
        let r = DeploySnapshot.readOutcome()
        let base: DeploySnapshot? = r.snapshot ?? (preview ? DeploySnapshot.sample : nil)
        let snap = base?.filtered(platform: c.platform.name, onlyFailed: c.onlyFailed)
        return Entry(date: Date(), snap: snap, problem: r.problem)
    }
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func snapshot(for configuration: FilterIntent, in context: Context) async -> Entry { entry(configuration, preview: context.isPreview) }
    func timeline(for configuration: FilterIntent, in context: Context) async -> Timeline<Entry> {
        let e = entry(configuration, preview: false)
        var entries = [e]
        // A second entry once the snapshot is three hours old, so "out of date" shows without the app (as in Provider).
        if let s = e.snap, let d = WidgetRefresh.staleEntryDate(snapshotAt: s.at, now: e.date) { entries.append(Entry(date: d, snap: s)) }
        return Timeline(entries: entries, policy: .after(WidgetRefresh.nextReload(snapshotAt: e.snap?.at, building: e.snap?.building ?? 0, now: e.date)))
    }
}

/// The same picture as the first widget, for one platform or only failures. Configured by long press → Edit Widget.
struct FilteredWidget: Widget {
    static let kind = "DeployCenterFiltered"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: FilterIntent.self, provider: FilteredProvider()) { DeployWidgetView(entry: $0) }
            .configurationDisplayName(Words(DeploySnapshot.read())("Deploy Center, filtered", "Deploy Center, gefiltert"))
            .description(Words(DeploySnapshot.read())("One platform, or only failed deploys.", "Eine Plattform oder nur fehlgeschlagene Deploys."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Control Center and the Action button: reads the list again. A tap opens the app, which reads it (the extension holds no keys).
struct RefreshControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        let w = Words(DeploySnapshot.read())
        return StaticControlConfiguration(kind: "app.deploycenter.ios.control.refresh") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "deploycenter://reload")!)) {
                Label(w("Refresh now", "Jetzt aktualisieren"), systemImage: "arrow.clockwise")
            }
        }
        .displayName(LocalizedStringResource(String.LocalizationValue(w("Refresh now", "Jetzt aktualisieren"))))
        .description(LocalizedStringResource(String.LocalizationValue(w("Opens Deploy Center and reads your projects again.", "Öffnet Deploy Center und liest deine Projekte neu."))))
    }
}

/// Control Center, lock screen and Action button (iOS 18): the waiting PRs, a tap opens the app.
/// Only reads the snapshot: the extension holds no keys, so it cannot read the accounts itself.
struct WaitingControl: ControlWidget {
    struct Value: ControlValueProvider {
        var previewValue: Int { 3 }
        /// -1: not known (no snapshot yet, no account, or an old one): never "0 PRs" then.
        func currentValue() async throws -> Int {
            guard let s = DeploySnapshot.read(), s.connected != false, !s.isStale(at: Date()) else { return -1 }
            return s.waitingPRs
        }
    }
    var body: some ControlWidgetConfiguration {
        let w = Words(DeploySnapshot.read())
        return StaticControlConfiguration(kind: "app.deploycenter.ios.control.waiting", provider: Value()) { n in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "deploycenter://")!)) {
                if n < 0 { Label(w("Open Deploy Center", "Deploy Center öffnen"), systemImage: "paperplane") }
                else { Label(w.n(n, ("PR waiting", "PR wartet"), ("PRs waiting", "PRs warten")), systemImage: n > 0 ? "arrow.up.circle.fill" : "paperplane") }
            }
        }
        .displayName(LocalizedStringResource(String.LocalizationValue(w("Waiting PRs", "Wartende PRs"))))
        .description(LocalizedStringResource(String.LocalizationValue(w("Opens Deploy Center.", "Öffnet Deploy Center."))))
    }
}

/// The Live Activity of a deploy the iPhone app follows (ios/Common/DeployActivity.swift).
struct DeployActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeployActivity.self) { ctx in
            DeployActivityView(ctx: ctx).padding()
                .activityBackgroundTint(nil)
                .widgetURL(activityLink(ctx.attributes))
        } dynamicIsland: { ctx in
            let w = Words(german: ctx.attributes.german)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { phaseIcon(ctx.state.phase, w, rollback: ctx.attributes.rollback).font(.title2) }
                DynamicIslandExpandedRegion(.trailing) { elapsed(ctx).font(.title3.monospacedDigit()) }
                DynamicIslandExpandedRegion(.center) { Text(ctx.attributes.project).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(line(ctx, w)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } compactLeading: {
                phaseIcon(ctx.state.phase, w, rollback: ctx.attributes.rollback)
            } compactTrailing: {
                // 1:00:00 and longer scale down instead of being cut off.
                elapsed(ctx).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 56)
            } minimal: {
                phaseIcon(ctx.state.phase, w, rollback: ctx.attributes.rollback)
            }
            .widgetURL(activityLink(ctx.attributes))
        }
    }
}

private func activityLink(_ a: DeployActivity) -> URL {
    var c = URLComponents(); c.scheme = "deploycenter"; c.host = "select"
    c.queryItems = [URLQueryItem(name: "project", value: a.project), URLQueryItem(name: "platform", value: a.platform)]
    if let k = a.key { c.queryItems?.append(URLQueryItem(name: "key", value: k)) }
    return c.url ?? URL(string: "deploycenter://")!
}

private func phaseIcon(_ p: DeployActivity.ContentState.Phase, _ w: Words, rollback: Bool = false) -> some View {
    let (name, color, label): (String, Color, String) = switch p {
    case .running where rollback: ("arrow.uturn.backward.circle.fill", .orange, w("Rolling back", "Wird zurückgerollt"))
    case .running: ("hammer.fill", .orange, w("Building", "Wird gebaut"))
    case .live: ("checkmark.circle.fill", .green, w("Live", "Live"))
    case .failed: ("xmark.octagon.fill", .red, w("Failed", "Fehlgeschlagen"))
    case .unknown: ("questionmark.circle.fill", .secondary, w("Unknown", "Unbekannt"))
    }
    // VoiceOver reads the state ("Building"), not the symbol's name ("hammer fill").
    return Image(systemName: name).foregroundStyle(color).accessibilityLabel(label)
}

/// Running: a clock from the start. Ended: the time it took.
@ViewBuilder private func elapsed(_ ctx: ActivityViewContext<DeployActivity>) -> some View {
    let w = Words(german: ctx.attributes.german)
    if ctx.state.phase == .running && !ctx.isStale {
        // VoiceOver says what the number is: "Running for", then the clock.
        Text(timerInterval: ctx.attributes.started...Date.distantFuture, countsDown: false)
            .accessibilityLabel(w("Running for", "Läuft seit"))
            .accessibilityValue(Text(timerInterval: ctx.attributes.started...Date.distantFuture, countsDown: false))
    } else {
        let t = Duration.seconds(max(0, ctx.state.updated.timeIntervalSince(ctx.attributes.started))).formatted(.time(pattern: .minuteSecond))
        Text(t).accessibilityLabel(w("Took \(t)", "Dauerte \(t)"))
    }
}

/// "Building · Vercel", or, when the app stopped updating, how old the state is.
private func line(_ ctx: ActivityViewContext<DeployActivity>, _ w: Words) -> String {
    let what = ctx.state.words + " · " + ctx.attributes.platform
    guard ctx.isStale && ctx.state.phase == .running else { return what }
    let t = ctx.state.updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(w.locale))
    // Plain: the time of the last update, not an instruction (IDEEN-12 C27).
    return what + w(" · as of \(t)", " · Stand \(t)")
}

struct DeployActivityView: View {
    let ctx: ActivityViewContext<DeployActivity>
    @ScaledMetric(relativeTo: .title3) private var timeWidth = 80.0
    var body: some View {
        let w = Words(german: ctx.attributes.german)
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
            phaseIcon(ctx.state.phase, w, rollback: ctx.attributes.rollback).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text((ctx.attributes.rollback ? w("Rollback: ", "Zurückrollen: ") : "") + ctx.attributes.project).font(.headline).lineLimit(1)
                Text(line(ctx, w)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            // The width grows with Dynamic Type, and 1:05:00 scales down instead of being cut off.
            elapsed(ctx).font(.title3.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
                .frame(maxWidth: timeWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        // A bar over the usual build time (it runs on its own clock, no updates needed), and the domain once it is live.
        VStack(alignment: .leading, spacing: 6) {
            if ctx.state.phase == .running, !ctx.isStale, let t = ctx.state.expected, t >= 10 {
                ProgressView(timerInterval: ctx.attributes.started...ctx.attributes.started.addingTimeInterval(t), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .accessibilityHidden(true)
            }
            if ctx.state.phase == .live, !ctx.attributes.rollback, let d = ctx.attributes.domain, let u = URL(string: "https://" + d) {
                Link(w("Open \(d)", "\(d) öffnen"), destination: u).font(.subheadline)
            }
        }
        }
    }
}
#endif

@main
struct DeployWidgets: WidgetBundle {
    var body: some Widget {
        DeployWidget()
        ProblemsWidget()
        OutagesWidget()
        #if os(macOS)
        NextDeployWidget()    // the Mac app writes the schedule; the iPhone has none to show
        #endif
        #if os(iOS)
        DeployActivityWidget()
        WaitingControl()
        RefreshControl()
        FilteredWidget()
        #endif
    }
}
