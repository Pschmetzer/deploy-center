// Recent deploys of a project, the build log and the commit row.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The last deploys of one project: state, time, commit; a built one can go live again.
struct DeployHistoryView: View {
    @ObservedObject var store: PhoneStore
    let project: PhoneProject
    @State private var records: [DeployRecord]?
    @State private var again: DeployRecord?
    /// The list could not be read: that is not "no deploys yet".
    @State private var loadFailed = false

    var body: some View {
        List {
            if let records {
                if records.isEmpty && loadFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("The history could not be loaded.", "Der Verlauf konnte nicht geladen werden.")).foregroundStyle(.secondary)
                        Button(L("Try again", "Noch einmal versuchen")) { Task { await load() } }
                    }
                } else if records.isEmpty { Text(L("No deploys yet.", "Noch keine Deploys.")).foregroundStyle(.secondary) }
                else if loadFailed {
                    // The refresh failed: what is shown is the last read, and the list says so.
                    Label(L("Could not refresh. This is the last state read.", "Konnte nicht aktualisieren. Das ist der zuletzt gelesene Stand."),
                          systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.warningText)
                }
                ForEach(records) { r in
                    NavigationLink { BuildLogView(store: store, project: project, record: r) } label: { row(r) }
                        .swipeActions {
                            if r.reusable {
                                Button(L("Live again", "Wieder live")) { again = r }.tint(.orange)
                            }
                        }
                        .contextMenu {
                            if r.reusable { Button(L("Make live again …", "Wieder live schalten …"), systemImage: "arrow.uturn.backward") { again = r } }
                        }
                }
            } else { HStack { Spacer(); ProgressView().accessibilityLabel(L("Loading history", "Verlauf wird geladen")); Spacer() } }
        }
        .navigationTitle(L("History", "Verlauf"))
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(L("Make this deploy live again?", "Diesen Deploy wieder live schalten?"),
                            isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } }), titleVisibility: .visible,
                            presenting: again) { r in
            Button(L("Make live again", "Wieder live schalten"), role: .destructive) {
                Task { await store.rollback(project, to: r.target) }
            }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: { r in
            Text((r.title.map { L("\"\($0)\"", "„\($0)“") } ?? L("This deploy", "Dieser Deploy"))
                 + L(" goes live again. Asks for \(store.unlockName).", " geht wieder live. Fragt nach \(store.unlockName)."))
        }
    }

    /// A failed read keeps what is shown (refresh) and says so (first load) instead of an empty list.
    private func load() async {
        if let r = await store.history(project) { records = r; loadFailed = false }
        else { loadFailed = true; if records == nil { records = [] } }
    }

    private func row(_ r: DeployRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(PhoneProject.stateWord(r.state)).foregroundStyle(r.failed ? .red : r.current ? .green : .secondary)
                if r.current { Text(L("live now", "jetzt live")).font(.caption).foregroundStyle(.green) }
                Spacer()
                if let a = r.at { Text(relative(a)).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                if let s = r.sha { Text(s.prefix(7)).monospaced().font(.caption) }
                if let t = r.title { Text(t).font(.caption).lineLimit(1) }
            }.foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Build output around the first error, with secrets masked. Copy takes the whole masked log.
struct BuildLogView: View {
    @ObservedObject var store: PhoneStore
    let project: PhoneProject
    let record: DeployRecord?
    @State private var log: BuildLog?
    @State private var copied = false
    /// Filters the lines shown (the copied and shared text stays the whole masked log).
    @State private var find = ""

    private func load() async { log = nil; log = await store.buildLog(project, record) }

    var body: some View {
        Group {
            if let log {
                if let problem = log.problem {
                    ContentUnavailableView {
                        Label(L("No log", "Kein Log"), systemImage: "doc.text.magnifyingglass")
                    } description: { Text(problem) } actions: {
                        // A log that is not there yet (a deploy that just started) or a failed read: ask again (IDEEN-12 C50).
                        Button(L("Try again", "Erneut versuchen")) { Task { await load() } }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { i, l in
                                if find.isEmpty || l.localizedCaseInsensitiveContains(find) {
                                    Text(l.isEmpty ? " " : l).font(.caption.monospaced())
                                        .foregroundStyle(i == log.errorAt ? .red : .primary)
                                        .fontWeight(i == log.errorAt ? .bold : .regular)
                                        // Colour is no information for VoiceOver: the first error line says so (IDEEN-12 C45).
                                        .accessibilityLabel(i == log.errorAt ? L("Error: ", "Fehler: ") + l : l)
                                        .accessibilityAddTraits(i == log.errorAt ? .isHeader : [])
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .refreshable { await load() }
                    .searchable(text: $find, prompt: L("Find in the log", "Im Log suchen"))
                    .safeAreaInset(edge: .bottom) {
                        Text(log.errorAt != nil ? L("From shortly before the first error line. Secrets are masked as well as known, check before sharing.",
                                                    "Ab kurz vor der ersten Fehlerzeile. Geheimnisse sind nach bestem Wissen maskiert, vor dem Teilen prüfen.")
                                                  : L("The last lines. Secrets are masked as well as known, check before sharing.",
                                                      "Die letzten Zeilen. Geheimnisse sind nach bestem Wissen maskiert, vor dem Teilen prüfen."))
                            .font(.footnote).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.bar)
                    }
                }
            } else { ProgressView().accessibilityLabel(L("Loading log", "Log wird geladen")) }
        }
        .navigationTitle(L("Build log", "Build-Log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let full = log?.full, !full.isEmpty {
                Button {
                    // Only on this device, gone after ten minutes: a log is no thing for Universal Clipboard.
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: full]],
                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                    copied = true
                } label: { Label(copied ? L("Copied", "Kopiert") : L("Copy", "Kopieren"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                // The masked text only, like Copy (IDEEN-12 C50).
                ShareLink(item: full) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(L("Share the masked log", "Maskiertes Log teilen"))
            }
        }
        // "Copied" is said once and goes back to "Copy" (IDEEN-12 C44).
        .task(id: copied) {
            guard copied else { return }
            AccessibilityNotification.Announcement(L("Copied", "Kopiert")).post()
            try? await Task.sleep(for: .seconds(3))
            copied = false
        }
        .task { await load() }
    }
}

extension PhoneStore {
    /// The state as text, for a chat or a ticket.
    var shareText: String {
        var lines = [L("Deploy Center: \(plural(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten")))",
                       "Deploy Center: \(plural(waitingPRs, ("PR", "PR"), ("PRs", "PRs"))) warten in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten")))")]
        for p in projects where p.group != .live { lines.append("• \(p.name) (\(p.provider.rawValue)): \(p.stateText)") }
        if demo { lines.append(L("(demo data)", "(Demodaten)")) }
        return lines.joined(separator: "\n")
    }
}

/// A commit, short, selectable, with "Copy" in its context menu.
struct ShaRow: View {
    let label: String
    let sha: String
    var body: some View {
        LabeledContent(label) {
            Text(String(sha.prefix(7))).font(.body.monospaced()).textSelection(.enabled)
        }
        .contextMenu {
            Button { UIPasteboard.general.string = sha } label: { Label(L("Copy", "Kopieren"), systemImage: "doc.on.doc") }
        }
        .accessibilityAction(named: L("Copy", "Kopieren")) { UIPasteboard.general.string = sha }
    }
}
