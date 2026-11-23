// Recent deploys of all projects in one timeline, newest first, grouped by day (read only).

import SwiftUI

struct RecentDeploysView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var days: [DeployTimeline.Day] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if days.isEmpty {
                    if loading { HStack { Spacer(); ProgressView().accessibilityLabel(L("Loading history", "Verlauf wird geladen")); Spacer() } }
                    else { Text(L("No deploys in the last 7 days.", "Keine Deploys in den letzten 7 Tagen.")).foregroundStyle(.secondary) }
                }
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { item in row(item) }
                    } header: {
                        Text(title(day)).accessibilityAddTraits(.isHeader)
                    } footer: {
                        if day.failures > 0 {
                            Text(L("\(day.failures) failed", "\(day.failures) fehlgeschlagen")).foregroundStyle(Color.warningText)
                        }
                    }
                }
            }
            .navigationTitle(L("Recent deploys", "Letzte Deploys"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done", "Fertig")) { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func title(_ d: DeployTimeline.Day) -> String {
        switch d.label {
        case .today: return L("Today", "Heute")
        case .yesterday: return L("Yesterday", "Gestern")
        case .date(let date): return date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(appLocale))
        }
    }

    private func row(_ item: DeployTimeline.Item) -> some View {
        let r = item.record
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.projectName).font(.headline).lineLimit(1)
                Spacer()
                Text(item.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(PhoneProject.stateWord(r.state)).foregroundStyle(r.failed ? .red : r.current ? .green : .secondary)
                if let t = r.title { Text(t).lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The cached lists first (offline), then the newest few projects once more; the list grows as each one answers.
    private func load() async {
        var read: [String: [DeployRecord]] = [:]
        for p in store.projects { if let c = HistoryCache.load(p.key) { read[p.key] = c } }
        func show() {
            days = DeployTimeline.build(store.projects.compactMap { p in read[p.key].map { DeployTimeline.Source(key: p.key, name: p.name, records: $0) } }, now: Date())
        }
        show()
        for p in store.projects.sorted(by: { ($0.latestAt ?? .distantPast) > ($1.latestAt ?? .distantPast) }).prefix(8) {
            if let r = await store.history(p, quiet: true) { read[p.key] = r; show() }
        }
        loading = false
    }
}
