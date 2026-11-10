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
        completion(Timeline(entries: [Entry(date: Date(), snap: DeploySnapshot.read())],
                            policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

/// The app's language (Settings → Language) comes with the snapshot; without one, the Mac's.
private func L(_ en: String, _ de: String) -> String {
    let lang = DeploySnapshot.read()?.language ?? Locale.preferredLanguages.first ?? "en"
    return lang.hasPrefix("de") ? de : en
}
private func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

struct SmallView: View {
    let snap: DeploySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Deploy Center", systemImage: "paperplane.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(snap.waitingPRs)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(snap.waitingPRs > 0 ? Color.accentColor : .secondary)
                .contentTransition(.numericText())
            Text(snap.waitingPRs == 1 ? L("PR waiting", "PR wartet") : L("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
            Text(snap.waitingProjects == 1 ? L("1 project", "1 Projekt") : L("\(snap.waitingProjects) projects", "\(snap.waitingProjects) Projekte")).font(.caption2).foregroundStyle(.secondary)
            StatusLine(snap: snap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
    }
}

struct MediumView: View {
    let snap: DeploySnapshot
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Deploy Center", systemImage: "paperplane.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(snap.waitingPRs)").font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(snap.waitingPRs > 0 ? Color.accentColor : .secondary)
                Text(snap.waitingPRs == 1 ? L("PR waiting", "PR wartet") : L("PRs waiting", "PRs warten")).font(.caption.weight(.medium))
                if let s = snap.saving, s.after < s.before {
                    Text(L("≈ \(money(s.month))/mo saved", "≈ \(money(s.month))/Monat gespart"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                if snap.projects.isEmpty {
                    Spacer()
                    Text(L("Nothing waits.", "Nichts wartet.")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(snap.projects.prefix(3)) { ProjectRow(p: $0) }
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
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
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
                if family == .systemSmall { SmallView(snap: s) } else { MediumView(snap: s) }
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
            .description(L("Waiting pull requests, builds, failures and the saving.",
                           "Wartende Pull Requests, Builds, Fehler und die Ersparnis."))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct DeployWidgets: WidgetBundle {
    var body: some Widget { DeployWidget() }
}
