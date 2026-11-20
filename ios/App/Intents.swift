// Deploy Center for iPhone — Siri, Shortcuts and Spotlight: read-only questions about the last state read.
// No deploy here: a deploy asks for Face ID in the app, and a voice command is no place for that.

import AppIntents
import Foundation

extension Spoken {
    /// The state the app saved last (the background refresh saves it too). Nil: nothing read yet.
    static func last() -> (projects: [PhoneProject], at: Date)? {
        if UserDefaults.standard.bool(forKey: "demo") { return (DemoData.projects(), Date()) }
        return Background.loadLast()
    }
}

struct WaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "What waits to deploy"
    static let description = IntentDescription("Waiting pull requests and failed deploys, from the state Deploy Center read last.")
    /// Project names and failures are not for a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// The dialog for Siri, and the number of waiting PRs as a value a Shortcut can use (-1: nothing read yet).
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let (text, prs) = await MainActor.run { () -> (String, Int) in
            guard let l = Spoken.last() else { return (L("Nothing read yet: open Deploy Center once.", "Noch nichts gelesen: öffne Deploy Center einmal."), -1) }
            return (Spoken.waiting(l.projects, at: l.at, hideNames: PhoneStore.lockOnOpen), l.projects.waitingPRCount)
        }
        return .result(value: prs, dialog: IntentDialog(stringLiteral: text))
    }
}

struct FailuresIntent: AppIntent {
    static let title: LocalizedStringResource = "Failed deploys"
    static let description = IntentDescription("Which projects failed, from the state Deploy Center read last.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await MainActor.run {
            guard let l = Spoken.last() else { return L("Nothing read yet: open Deploy Center once.", "Noch nichts gelesen: öffne Deploy Center einmal.") }
            return Spoken.failures(l.projects.filter(\.failed), hideNames: PhoneStore.lockOnOpen) + Spoken.age(l.at)
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// A project as Shortcuts and Siri know it: from the last state read. With "Unlock on open" none is offered (the names stay behind the lock).
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()
    var id: String
    var name: String
    var platform: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(platform)") }
}

struct ProjectQuery: EntityQuery {
    private func all() async -> [ProjectEntity] {
        await MainActor.run {
            guard !PhoneStore.lockOnOpen, let l = Spoken.last() else { return [] }
            return l.projects.map { ProjectEntity(id: $0.key, name: $0.name, platform: $0.provider.rawValue) }
        }
    }
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] { await all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [ProjectEntity] { await all() }
}

/// Opens a project in the app. Shows it; starts nothing.
struct OpenProjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a project"
    static let description = IntentDescription("Shows a project in Deploy Center.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Project") var target: ProjectEntity

    @MainActor func perform() async throws -> some IntentResult {
        PhoneStore.shared.openKey = target.id
        return .result()
    }
}

/// Opens the question "Deploy this project?" in the app. Nothing starts: the question still needs a tap and Face ID, Touch ID or the code.
struct PrepareDeployIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare a deploy"
    static let description = IntentDescription("Opens the confirmation for a deploy. Nothing starts until you confirm it with Face ID.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Project") var project: ProjectEntity

    @MainActor func perform() async throws -> some IntentResult {
        PhoneStore.shared.confirmDeployKey = project.id
        return .result()
    }
}

struct DeployCenterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WaitingIntent(), phrases: ["What waits in \(.applicationName)", "What is waiting in \(.applicationName)"],
                    shortTitle: "What waits", systemImageName: "clock")
        AppShortcut(intent: FailuresIntent(), phrases: ["Failed deploys in \(.applicationName)", "What failed in \(.applicationName)"],
                    shortTitle: "Failed deploys", systemImageName: "exclamationmark.triangle")
    }
}

// MARK: - Spotlight and Handoff

import CoreSpotlight

enum Spotlight {
    /// The activity of an open project: continues on another iPhone or iPad of the same person.
    static let activity = "app.deploycenter.project"
    /// nil: not written in this launch yet (an earlier launch may have left items behind).
    private static var indexed: [String]? = nil
    private static var indexedIDs: Set<String> = []

    /// Project names in Spotlight, opening the project. Demo projects are not indexed, and neither is anything when
    /// "Keep out of Spotlight" is on (the domain would sit in the system-wide index); only when the list changed.
    /// The new items are written first and only the ones that are gone are removed: no gap where a project is missing.
    @MainActor static func index(_ projects: [PhoneProject], demo: Bool) {
        // No key (or "Remove all keys"): nothing of the account may stay in the system-wide index.
        let off = demo || projects.isEmpty || UserDefaults.standard.bool(forKey: "noSpotlight") || PhoneStore.lockOnOpen
        let keys = off ? [] : projects.map { $0.key + "|" + $0.name + "|" + ($0.domain ?? "") }
        guard keys != indexed else { return }
        indexed = keys
        let idx = CSSearchableIndex.default()
        let now = off ? Set<String>() : Set(projects.map(\.key))
        let gone = Array(indexedIDs.subtracting(now))
        indexedIDs = now
        if off {
            // Also what an earlier launch left behind: the index outlives the process.
            idx.deleteAllSearchableItems { _ in }
            return
        }
        let items = projects.map { p in
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = p.name
            a.contentDescription = p.provider.rawValue + (p.domain.map { " · " + $0 } ?? "")
            // Found by "deploy", "vercel" or the like too, not only by the name (IDEEN-12 C36).
            a.keywords = ["deploy", p.provider.rawValue, "Deploy Center"]
            return CSSearchableItem(uniqueIdentifier: p.key, domainIdentifier: "projects", attributeSet: a)
        }
        idx.indexSearchableItems(items) { _ in
            if !gone.isEmpty { idx.deleteSearchableItems(withIdentifiers: gone) { _ in } }
        }
    }

    /// The project key of a Spotlight hit or a handed-off activity.
    static func key(_ a: NSUserActivity) -> String? {
        if a.activityType == CSSearchableItemActionType { return a.userInfo?[CSSearchableItemActivityIdentifier] as? String }
        return a.userInfo?["project"] as? String
    }
}
