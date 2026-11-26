// The questions before a deploy or a rollback, and the keyboard commands of the window.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The questions before a deploy or a rollback, asked in one place for the list, the details,
/// VoiceOver actions, the context menu and the keyboard.
@MainActor
final class Asks: ObservableObject {
    @Published var deploy: PhoneProject?
    /// Several waiting projects at once: one question, one Face ID.
    @Published var deployAll: [PhoneProject]?
    @Published var rollback: (project: PhoneProject, target: RollbackTarget)?
    /// The project whose rollback target is being looked up.
    @Published var finding: String?

    func askRollback(_ p: PhoneProject, _ store: PhoneStore) {
        guard finding == nil else { return }
        finding = p.key
        Task {
            defer { finding = nil }
            store.message = nil
            if let t = await store.rollbackTarget(p) { rollback = (p, t) }
            else if store.message == nil { store.say(L("Nothing to roll back to.", "Nichts zum Zurückrollen.")) }
        }
    }
    /// Offline: off, and the list says why (a banner), instead of a deploy that fails after the question.
    func canDeploy(_ p: PhoneProject, _ store: PhoneStore) -> Bool { p.deployable && !p.building && store.running[p.key] == nil && !store.offline }
    func canRollBack(_ p: PhoneProject, _ store: PhoneStore) -> Bool {
        finding == nil && !p.paused && !p.building && store.running[p.key] == nil && !store.offline
    }
}

/// What the keyboard shortcuts of the focused window act on (iPad with a keyboard).
struct DeployActions {
    let reload: () -> Void
    let settings: () -> Void
    let deploy: (() -> Void)?
}
extension FocusedValues {
    @Entry var deployActions: DeployActions?
}

struct DeployCommands: Commands {
    @FocusedValue(\.deployActions) private var actions
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("Reload", "Neu laden")) { actions?.reload() }
                .keyboardShortcut("r").disabled(actions == nil)
            Button(L("Deploy the selected project …", "Ausgewähltes Projekt deployen …")) { actions?.deploy?() }
                .keyboardShortcut("d").disabled(actions?.deploy == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("Settings …", "Einstellungen …")) { actions?.settings() }
                .keyboardShortcut(",").disabled(actions == nil)
        }
    }
}

extension View {
    /// The deploy and rollback questions; `asks` says which one is open.
    func deployQuestions(store: PhoneStore, asks: Asks) -> some View { modifier(DeployQuestions(store: store, asks: asks)) }
}

struct DeployQuestions: ViewModifier {
    @ObservedObject var store: PhoneStore
    @ObservedObject var asks: Asks

    func body(content: Content) -> some View {
        let p = asks.deploy
        // Already on the newest commit: say so, as the Mac app does; a build changes nothing and costs minutes.
        let nothingNew = p?.upToDate ?? false
        content
            .confirmationDialog(nothingNew ? L("Nothing new to deploy", "Nichts Neues zu deployen")
                                           : L("Deploy \(p?.name ?? "")?", "\(p?.name ?? "") deployen?"),
                                isPresented: Binding(get: { asks.deploy != nil }, set: { if !$0 { asks.deploy = nil } }),
                                titleVisibility: .visible, presenting: p) { p in
                Button(nothingNew ? L("Build anyway", "Trotzdem bauen") : L("Deploy", "Deployen")) { Task { await store.deploy(p) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { p in
                if nothingNew {
                    Text(L("\(p.name) is already on the newest commit. A build costs build minutes and changes nothing.",
                           "\(p.name) ist schon auf dem neuesten Stand. Ein Build kostet Build-Minuten und ändert nichts."))
                } else {
                    Text(p.deploySummary)
                }
            }
            .confirmationDialog(L("Deploy \(asks.deployAll?.count ?? 0) projects?", "\(asks.deployAll?.count ?? 0) Projekte deployen?"),
                                isPresented: Binding(get: { asks.deployAll != nil }, set: { if !$0 { asks.deployAll = nil } }),
                                titleVisibility: .visible, presenting: asks.deployAll) { all in
                Button(L("Deploy all", "Alle deployen")) { Task { await store.deployMany(all) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { all in
                Text(PhoneProject.nameList(all.map(\.name)) + L(". Each build can cost build minutes. One \(store.unlockName) question for all.",
                                                                  ". Jeder Build kann Build-Minuten kosten. Eine \(store.unlockName)-Frage für alle."))
            }
            .confirmationDialog(L("Roll back \(asks.rollback?.project.name ?? "")?", "\(asks.rollback?.project.name ?? "") zurückrollen?"),
                                isPresented: Binding(get: { asks.rollback != nil }, set: { if !$0 { asks.rollback = nil } }),
                                titleVisibility: .visible, presenting: asks.rollback) { r in
                Button(L("Roll back", "Zurückrollen"), role: .destructive) { Task { await store.rollback(r.project, to: r.target) } }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { r in
                Text(Self.describe(r.target))
            }
    }

    /// "a1b2c3d “Fix the header”, from 3 days ago"; without a commit the deploy id names it.
    static func describe(_ t: RollbackTarget) -> String {
        var what = t.sha.map { String($0.prefix(7)) } ?? String(t.id.prefix(24))
        if let m = t.title, !m.isEmpty { what += " “\(m)”" }
        if let d = t.at { what += L(", from ", ", vom ") + d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)) }
        return L("The previous deploy goes live again: \(what).", "Der vorige Deploy geht wieder live: \(what).")
    }
}
