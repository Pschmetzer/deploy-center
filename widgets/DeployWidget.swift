// Deploy Center — Widgets: what waits, what builds, what failed, and the saving.
// Reads the snapshot the app writes to the App Group container; never calls a network.

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
        // The app asks for a reload after each change; this is only the fallback.
        let now = Date(), snap = DeploySnapshot.read()
        var entries = [Entry(date: now, snap: snap)]
        // One more entry when the data turns old, so the widget greys out without being reloaded.
        if let at = snap?.at, at.addingTimeInterval(Entry.staleAfter) > now {
            entries.append(Entry(date: at.addingTimeInterval(Entry.staleAfter), snap: snap))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

extension Entry {
    /// After this long without a fresh snapshot the iPhone widget shows its numbers grey.
    static let staleAfter: TimeInterval = 6 * 3600
    /// Only on iOS: there the app is often not running for hours. The Mac app keeps the time of the
    /// last change in the snapshot, not of the last look, so an old time there would mislead.
    var stale: Bool {
        #if os(iOS)
        guard let at = snap?.at else { return false }
        return date.timeIntervalSince(at) >= Self.staleAfter
        #else
        return false
        #endif
    }
}

/// Texts without a snapshot: the system's language.
private func L(_ en: String, _ de: String) -> String { DeploySnapshot.localized(nil, en, de) }

/// "Deploy Center", with "Demo" when the numbers are made up, and on iOS the time of the data.
struct Header: View {
    let snap: DeploySnapshot
    var body: some View {
        HStack(spacing: 4) {
            Label("Deploy Center", systemImage: "paperplane.fill").lineLimit(1).minimumScaleFactor(0.7)
            if snap.demo {
                Text(snap.text("Demo", "Demo")).padding(.horizontal, 4)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// "as of 10:42" (or with the day, when it is not today), only on iOS.
struct AgeLine: View {
    let snap: DeploySnapshot
    let stale: Bool
    var body: some View {
        #if os(iOS)
        let today = Calendar.current.isDateInToday(snap.at)
        let when = today ? snap.at.formatted(date: .omitted, time: .shortened) : snap.at.formatted(.dateTime.day().month().hour().minute())
        Text(snap.text("as of ", "Stand ") + when)
            .font(.caption2).foregroundStyle(stale ? .orange : .secondary).lineLimit(1).minimumScaleFactor(0.7)
        #endif
    }
}
private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

struct SmallView: View {
    let snap: DeploySnapshot
    var stale = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(snap: snap)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                // Scales with the text size, and shrinks instead of being cut off.
                Text("\(snap.waitingPRs)").font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(snap.waitingPRs > 0 && !stale ? Color.accentColor : .secondary)
                    .contentTransition(.numericText())
                Text(snap.waitingPRs == 1 ? snap.text("PR waiting", "PR wartet") : snap.text("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(snap.waitingProjects == 1 ? snap.text("1 project", "1 Projekt") : snap.text("\(snap.waitingProjects) projects", "\(snap.waitingProjects) Projekte")).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                StatusLine(snap: snap)
                AgeLine(snap: snap, stale: stale)
            }
            // One element for VoiceOver: "5 PRs waiting, 3 projects, 1 building".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summaryLabel(snap))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The numbers of the widget as one sentence for VoiceOver.
func summaryLabel(_ snap: DeploySnapshot) -> String {
    let L = snap.text
    var parts = [snap.waitingPRs == 1 ? L("1 PR waiting", "1 PR wartet") : L("\(snap.waitingPRs) PRs waiting", "\(snap.waitingPRs) PRs warten"),
                 snap.waitingProjects == 1 ? L("1 project", "1 Projekt") : L("\(snap.waitingProjects) projects", "\(snap.waitingProjects) Projekte")]
    if snap.building > 0 { parts.append(L("\(snap.building) building", snap.building == 1 ? "1 baut" : "\(snap.building) bauen")) }
    if snap.failed > 0 { parts.append(L("\(snap.failed) failed", "\(snap.failed) fehlgeschlagen")) }
    if snap.demo { parts.append(L("demo data", "Demodaten")) }
    return parts.joined(separator: ", ")
}

struct StatusLine: View {
    let snap: DeploySnapshot
    var body: some View {
        HStack(spacing: 8) {
            if snap.building > 0 { Label("\(snap.building)", systemImage: "hammer.fill").foregroundStyle(.blue) }
            if snap.failed > 0 { Label("\(snap.failed)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
        .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
    }
}

struct MediumView: View {
    let snap: DeploySnapshot
    var stale = false
    @ScaledMetric(relativeTo: .caption) private var columnWidth = 104.0
    var body: some View {
        let L = snap.text
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Header(snap: snap)
                Spacer(minLength: 0)
                Group {
                    Text("\(snap.waitingPRs)").font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(snap.waitingPRs > 0 && !stale ? Color.accentColor : .secondary)
                    Text(snap.waitingPRs == 1 ? L("PR waiting", "PR wartet") : L("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let s = snap.saving, s.after < s.before {
                        Text(L("≈ \(money(s.month))/mo saved", "≈ \(money(s.month))/Monat gespart"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            .lineLimit(2).minimumScaleFactor(0.7)
                    }
                    AgeLine(snap: snap, stale: stale)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summaryLabel(snap) + (snap.saving.map { $0.after < $0.before ? ", " + L("≈ \(money($0.month))/mo saved", "≈ \(money($0.month))/Monat gespart") : "" } ?? ""))
            }
            // Grows with the text size.
            .frame(minWidth: 0, idealWidth: columnWidth, maxWidth: columnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                if snap.projects.isEmpty {
                    Spacer()
                    Text(L("Nothing waits.", "Nichts wartet.")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(snap.projects.prefix(3)) { ProjectRow(p: $0, language: snap.language) }
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
    let language: String?
    private func L(_ en: String, _ de: String) -> String { DeploySnapshot.localized(language, en, de) }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                // Hidden on the Lock Screen and in StandBy while the device is locked.
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
        case .building: return L("building · \(p.platform)", "baut · \(p.platform)")
        case .failed: return L("failed · \(p.platform)", "fehlgeschlagen · \(p.platform)")
        case .waiting:
            let prs = p.prs == 1 ? L("1 PR · ", "1 PR · ") : p.prs > 1 ? L("\(p.prs) PRs · ", "\(p.prs) PRs · ") : ""
            // A waiting row with 0 commits means the count is unknown (e.g. rewritten history).
            if p.commits == 0 { return prs + L("count unknown · \(p.platform)", "Anzahl unbekannt · \(p.platform)") }
            return prs + (p.commits == 1 ? L("1 commit · \(p.platform)", "1 Commit · \(p.platform)")
                                         : L("\(p.commits) commits · \(p.platform)", "\(p.commits) Commits · \(p.platform)"))
        }
    }
}

struct NoSnapshotView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Deploy Center", systemImage: "paperplane.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(L("Open Deploy Center once to fill this widget.", "Öffne Deploy Center einmal, um dieses Widget zu füllen."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct DeployWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        Group {
            if let s = entry.snap {
                if family == .systemSmall { SmallView(snap: s, stale: entry.stale) } else { MediumView(snap: s, stale: entry.stale) }
            } else { NoSnapshotView() }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "deploycenter://"))
    }
}

struct DeployWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeployCenterWaiting", provider: Provider()) { DeployWidgetView(entry: $0) }
            .configurationDisplayName("Deploy Center")
            .description(DeploySnapshot.localized(DeploySnapshot.read()?.language,
                                                  "Waiting pull requests, builds, failures and the saving.",
                                                  "Wartende Pull Requests, Builds, Fehler und die Ersparnis."))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DeployWidgets: WidgetBundle {
    var body: some Widget { DeployWidget() }
}
