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
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        // The gallery shows made-up numbers until the app has written a snapshot.
        completion(Entry(date: Date(), snap: DeploySnapshot.read() ?? (context.isPreview ? .sample : nil)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a reload after each change; this is only the fallback. A second entry once
        // the snapshot is three hours old, so "out of date" shows without the app (iOS only, see isStale).
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
        german = DeploySnapshot.localized(snap?.language, "en", "de") == "de"
    }
    init(german: Bool) { self.german = german }
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
            let when = Calendar.current.isDate(snap.at, inSameDayAs: date) ? snap.at.formatted(date: .omitted, time: .shortened)
                                                                           : snap.at.formatted(.dateTime.day().month().hour().minute())
            Text(snap.isStale(at: date) ? w("old: ", "alt: ") + when : when)
                .foregroundStyle(snap.isStale(at: date) ? Color.orange : .secondary)
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
            .lineLimit(1).minimumScaleFactor(0.5)
            .contentTransition(.numericText())
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

/// Medium (three rows), large (six) and extra large (ten, iPad and Mac).
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
                    Text(w("≈ \(money(s.month))/mo saved", "≈ \(money(s.month))/Monat gespart"))
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
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: 14).widgetAccentable().accessibilityHidden(true)
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

/// Only what failed or builds, with a tap to open it. Mac and iPhone.
struct ProblemsWidget: Widget {
    static let kind = "DeployCenterProblems"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { ProblemsWidgetView(entry: $0) }
            .configurationDisplayName(Words(DeploySnapshot.read())("Failed deploys", "Fehlgeschlagene Deploys"))
            .description(Words(DeploySnapshot.read())("Only the projects whose deploy failed or still builds.",
                                                      "Nur die Projekte, deren Deploy fehlschlug oder noch baut."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ProblemsWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            if let s = entry.snap, s.connected != false { ProblemsView(snap: s, date: entry.date, rows: family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2) }
            else { NoSnapshotView(notConnected: entry.snap?.connected == false) }
        }
        .environment(\.words, Words(entry.snap))
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "deploycenter://"))
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
            if bad.isEmpty {
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

#if os(iOS)
/// Control Center, lock screen and Action button (iOS 18): the waiting PRs, a tap opens the app.
/// Only reads the snapshot: the extension holds no keys, so it cannot read the accounts itself.
struct WaitingControl: ControlWidget {
    struct Value: ControlValueProvider {
        var previewValue: Int { 3 }
        func currentValue() async throws -> Int { DeploySnapshot.read()?.waitingPRs ?? 0 }
    }
    var body: some ControlWidgetConfiguration {
        let w = Words(DeploySnapshot.read())
        return StaticControlConfiguration(kind: "app.deploycenter.ios.control.waiting", provider: Value()) { n in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "deploycenter://")!)) {
                Label(w.n(n, ("PR waiting", "PR wartet"), ("PRs waiting", "PRs warten")), systemImage: n > 0 ? "arrow.up.circle.fill" : "paperplane")
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
                DynamicIslandExpandedRegion(.leading) { phaseIcon(ctx.state.phase).font(.title2) }
                DynamicIslandExpandedRegion(.trailing) { elapsed(ctx).font(.title3.monospacedDigit()) }
                DynamicIslandExpandedRegion(.center) { Text(ctx.attributes.project).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(line(ctx, w)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } compactLeading: {
                phaseIcon(ctx.state.phase)
            } compactTrailing: {
                elapsed(ctx).monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                phaseIcon(ctx.state.phase)
            }
            .widgetURL(activityLink(ctx.attributes))
        }
    }
}

private func activityLink(_ a: DeployActivity) -> URL {
    var c = URLComponents(); c.scheme = "deploycenter"; c.host = "select"
    c.queryItems = [URLQueryItem(name: "project", value: a.project), URLQueryItem(name: "platform", value: a.platform)]
    return c.url ?? URL(string: "deploycenter://")!
}

private func phaseIcon(_ p: DeployActivity.ContentState.Phase) -> some View {
    let (name, color): (String, Color) = switch p {
    case .running: ("hammer.fill", .orange)
    case .live: ("checkmark.circle.fill", .green)
    case .failed: ("xmark.octagon.fill", .red)
    case .unknown: ("questionmark.circle.fill", .secondary)
    }
    return Image(systemName: name).foregroundStyle(color)
}

/// Running: a clock from the start. Ended: the time it took.
@ViewBuilder private func elapsed(_ ctx: ActivityViewContext<DeployActivity>) -> some View {
    if ctx.state.phase == .running && !ctx.isStale {
        Text(timerInterval: ctx.attributes.started...Date.distantFuture, countsDown: false)
    } else {
        Text(Duration.seconds(max(0, ctx.state.updated.timeIntervalSince(ctx.attributes.started))).formatted(.time(pattern: .minuteSecond)))
    }
}

/// "Building · Vercel", or, when the app stopped updating, how old the state is.
private func line(_ ctx: ActivityViewContext<DeployActivity>, _ w: Words) -> String {
    let what = ctx.state.words + " · " + ctx.attributes.platform
    guard ctx.isStale && ctx.state.phase == .running else { return what }
    let t = ctx.state.updated.formatted(date: .omitted, time: .shortened)
    return what + w(" · as of \(t), open the app to update", " · Stand \(t), App öffnen zum Aktualisieren")
}

struct DeployActivityView: View {
    let ctx: ActivityViewContext<DeployActivity>
    var body: some View {
        let w = Words(german: ctx.attributes.german)
        HStack(spacing: 12) {
            phaseIcon(ctx.state.phase).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text((ctx.attributes.rollback ? w("Rollback: ", "Zurückrollen: ") : "") + ctx.attributes.project).font(.headline).lineLimit(1)
                Text(line(ctx, w)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            elapsed(ctx).font(.title3.monospacedDigit()).multilineTextAlignment(.trailing).frame(maxWidth: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

@main
struct DeployWidgets: WidgetBundle {
    var body: some Widget {
        DeployWidget()
        ProblemsWidget()
        #if os(iOS)
        DeployActivityWidget()
        WaitingControl()
        #endif
    }
}
