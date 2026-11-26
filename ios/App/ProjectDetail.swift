// The details of one project.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct ProjectDetail: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks
    let project: PhoneProject
    @State private var confirmCancel = false
    @State private var renderAction: RenderAction?
    @State private var confirmAuto = false

    var body: some View {
        let p = project
        let busy = store.running[p.key] != nil
        List {
            Section {
                LabeledContent(L("Status", "Status")) {
                    // A deploy followed here shows its live state, like the row does (IDEEN-12 C9).
                    if let r = store.running[p.key] {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text(r == "rollback" ? PhoneProject.stateWord(r) : L("deploying: ", "deployt: ") + PhoneProject.stateWord(r))
                        }.foregroundStyle(Color.activeText)
                    } else {
                        HStack(spacing: 6) { Image(systemName: p.icon).accessibilityHidden(true); Text(p.stateText) }.foregroundStyle(p.tint)
                    }
                }
                LabeledContent(L("Platform", "Plattform"), value: p.provider.rawValue)
                LabeledContent(L("Auto-deploy", "Auto-Deploy")) {
                    Text(p.autoDeploy ? L("on: every push builds", "an: jeder Push baut") : L("off", "aus"))
                        .foregroundStyle(p.autoDeploy ? Color.warningText : .secondary)
                }
                if let r = p.repo { LabeledContent(L("Repository", "Repository"), value: r + (p.branch.map { " · \($0)" } ?? "")) }
                if let h = p.otherHost { LabeledContent(L("Repository", "Repository"), value: L("on \(h) (only GitHub is read)", "auf \(h) (gelesen wird nur GitHub)")) }
                if let d = p.domain { LabeledContent(L("Domain", "Domain"), value: d) }
                if let n = p.openPRs { LabeledContent(L("Open pull requests", "Offene Pull Requests"), value: "\(n)" + (p.openPRsCapped ? "+" : "")) }
                if let d = p.oldestPendingAt, p.changed {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        LabeledContent(L("Waiting since", "Wartet seit"), value: relative(d))
                    }
                }
                if let e = p.fetchError { Text(e).font(.footnote).foregroundStyle(Color.errorText) }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if p.autoDeploy && p.provider == .vercel {
                        Text(L("To turn it off for Vercel use the Mac app or `deploys vercel off`: it disconnects Git and remembers the repository.",
                               "Bei Vercel schaltest du es in der Mac-App oder mit `deploys vercel off` ab: Das trennt Git und merkt sich das Repository."))
                    }
                    if p.autoDeploy {
                        Text(L("Every push to \(p.branch ?? "the branch") builds and goes live, and each build can cost build minutes.",
                               "Jeder Push auf \(p.branch ?? "den Branch") baut und geht live, und jeder Build kann Build-Minuten kosten."))
                    }
                    if store.stale.contains(p.provider) {
                        Text(L("\(p.provider.rawValue) could not be read just now: this is the last state read.",
                               "\(p.provider.rawValue) war gerade nicht lesbar: das ist der zuletzt gelesene Stand."))
                    }
                }
            }
            Section(L("Commits", "Commits")) {
                if let m = p.headMsg { LabeledContent(L("Newest", "Neuester"), value: m) }
                if let m = p.liveMsg { LabeledContent(L("Live", "Live"), value: m) }
                // Both commits, so "SHA" is never ambiguous; long press copies the whole one.
                if let s = p.liveSha { ShaRow(label: L("Live commit", "Live-Commit"), sha: s) }
                if let s = p.headSha, s != p.liveSha { ShaRow(label: L("Newest commit", "Neuester Commit"), sha: s) }
            }
            .textSelection(.enabled)
            if p.changed, let titles = p.pendingTitles, !titles.isEmpty {
                Section {
                    ForEach(Array(titles.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                } header: { Text(L("Goes live with the next deploy", "Geht mit dem nächsten Deploy live")) } footer: {
                    if let n = p.pendingCommits, n > titles.count {
                        Text(L("Newest first; \(n - titles.count) older not shown.", "Neueste zuerst; \(n - titles.count) ältere nicht gezeigt."))
                    }
                }
            }
            Section(L("Deploys", "Deploys")) {
                if p.failed {
                    NavigationLink { BuildLogView(store: store, project: p, record: nil) } label: {
                        Label(L("Why it failed (log)", "Warum es fehlschlug (Log)"), systemImage: "exclamationmark.bubble")
                    }
                }
                NavigationLink { DeployHistoryView(store: store, project: p) } label: {
                    Label(L("History", "Verlauf"), systemImage: "clock.arrow.circlepath")
                }
            }
            if !store.demo, let links = links(p), !links.isEmpty {
                Section(L("Open", "Öffnen")) { ForEach(links, id: \.1) { Link($0.0, destination: $0.1) } }
            }
            Section {
                Button {
                    asks.deploy = p
                } label: {
                    Label(p.failed ? L("Deploy again …", "Erneut deployen …") : L("Deploy the newest commit …", "Neuesten Commit deployen …"),
                          systemImage: "paperplane")
                }
                .disabled(!asks.canDeploy(p, store))
                // A build that a push started: watch it here for the end note and the Live Activity.
                if p.building, store.running[p.key] == nil, p.latestId != nil, !store.offline {
                    Button { Task { await store.followBuild(p) } } label: { Label(L("Follow the build", "Build verfolgen"), systemImage: "eye") }
                }
                if store.buildId(p) != nil && (p.building || store.running[p.key].map { $0 != "rollback" && $0 != "starting" } == true) {
                    Button(role: .destructive) { confirmCancel = true } label: {
                        Label(L("Cancel the build …", "Build abbrechen …"), systemImage: "stop.circle")
                    }
                }
                Button(role: .destructive) {
                    asks.askRollback(p, store)
                } label: {
                    HStack {
                        Label(L("Roll back …", "Zurückrollen …"), systemImage: "arrow.uturn.backward")
                        if asks.finding == p.key { Spacer(); ProgressView() }
                    }
                }
                .disabled(!asks.canRollBack(p, store))
                if p.provider == .render {
                    ForEach(p.paused ? [RenderAction.resume] : [.restart, .suspend], id: \.self) { a in
                        Button(role: a == .suspend ? .destructive : nil) { renderAction = a } label: { Label(a.title, systemImage: a.icon) }
                            .disabled(busy || p.building)
                    }
                    Button { confirmAuto = true } label: {
                        Label(p.autoDeploy ? L("Turn off auto-deploy …", "Auto-Deploy abschalten …") : L("Turn on auto-deploy …", "Auto-Deploy einschalten …"),
                              systemImage: p.autoDeploy ? "bolt.slash" : "bolt")
                    }
                    .disabled(busy || p.paused)
                }
            } footer: {
                let how = store.unlockName
                Text(L("Each deploy, cancel and rollback asks for \(how). It goes straight from this device to \(p.provider.rawValue).",
                       "Jeder Deploy, jeder Abbruch und jedes Zurückrollen fragt nach \(how). Es geht direkt von diesem Gerät an \(p.provider.rawValue)."))
            }
        }
        .navigationTitle(p.name)
        .refreshable { await store.refreshByHand() }
        // With the app lock on, the project's name does not leave for other devices through Handoff.
        .userActivity(Spotlight.activity, isActive: !store.demo && !PhoneStore.lockOnOpen) { a in
            a.title = p.name; a.userInfo = ["project": p.key]
            a.isEligibleForHandoff = true; a.isEligibleForSearch = false
            // A Mac continues with the project's dashboard in its browser (IDEEN-12 C35); nothing is started by it.
            a.webpageURL = p.dashboardURL
        }
        .confirmationDialog(renderAction.map { $0.title.replacingOccurrences(of: " …", with: "?") } ?? "",
                            isPresented: Binding(get: { renderAction != nil }, set: { if !$0 { renderAction = nil } }), titleVisibility: .visible) {
            Button(renderAction?.title.replacingOccurrences(of: " …", with: "") ?? "", role: renderAction == .suspend ? .destructive : nil) {
                if let a = renderAction { Task { await store.serviceAction(p, a) } }
            }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(renderAction == .suspend ? L("The service stops answering until it is resumed.", "Der Dienst antwortet nicht mehr, bis er fortgesetzt wird.")
                 : renderAction == .restart ? L("The live deploy starts again; nothing is built.", "Der Live-Deploy startet neu; gebaut wird nichts.")
                 : L("The service starts again with its last deploy.", "Der Dienst startet wieder mit seinem letzten Deploy."))
        }
        .confirmationDialog(p.autoDeploy ? L("Turn off auto-deploy of \(p.name)?", "Auto-Deploy von \(p.name) abschalten?")
                                         : L("Turn on auto-deploy of \(p.name)?", "Auto-Deploy von \(p.name) einschalten?"),
                            isPresented: $confirmAuto, titleVisibility: .visible) {
            Button(p.autoDeploy ? L("Turn off", "Abschalten") : L("Turn on", "Einschalten")) { Task { await store.setAutoDeploy(p, on: !p.autoDeploy) } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(p.autoDeploy ? L("Pushes no longer build; you deploy by hand. This is the setting that saves build minutes.", "Pushes bauen nicht mehr; du deployst von Hand. Diese Einstellung spart Build-Minuten.")
                 : L("Every push builds and goes live again (On Commit).", "Jeder Push baut wieder und geht live (On Commit)."))
        }
        .confirmationDialog(L("Cancel the build of \(p.name)?", "Build von \(p.name) abbrechen?"), isPresented: $confirmCancel, titleVisibility: .visible) {
            Button(L("Cancel the build", "Build abbrechen"), role: .destructive) { Task { await store.cancelBuild(p) } }
            Button(L("Keep building", "Weiterbauen"), role: .cancel) {}
        } message: {
            Text(L("What is live stays live.", "Was live ist, bleibt live."))
        }
    }

    private func links(_ p: PhoneProject) -> [(String, URL)]? {
        var out: [(String, URL)] = []
        if let d = p.domain, let u = URL(string: "https://" + d) { out.append((d, u)) }
        if let r = p.repo, let u = URL(string: "https://github.com/" + r) {
            if let s = p.headSha, let c = URL(string: u.absoluteString + "/commit/" + s) { out.append((L("Newest commit on GitHub", "Neuester Commit auf GitHub"), c)) }
            if let l = p.liveSha, let h = p.headSha, l != h, let c = URL(string: u.absoluteString + "/compare/\(l)...\(h)") {
                out.append((L("What waits, on GitHub", "Was wartet, auf GitHub"), c))
            }
            if (p.openPRs ?? 0) > 0, let c = URL(string: u.absoluteString + "/pulls") {
                out.append((L("Open pull requests on GitHub", "Offene Pull Requests auf GitHub"), c))
            }
        }
        return out
    }
}
