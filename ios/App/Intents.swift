// Deploy Center for iPhone — Siri, Shortcuts and Spotlight: read-only questions about the last state read.
// No deploy here: a deploy asks for Face ID in the app, and a voice command is no place for that.

import AppIntents
import Foundation

enum Spoken {
    /// One answer for "what waits": PRs and projects waiting, failures by name, and how old the state is.
    static func waiting(_ projects: [PhoneProject], at: Date?, now: Date = Date(), hideNames: Bool = false) -> String {
        // The same rule and count as the app and the widgets (PhoneStore.waitingPRs).
        let waiting = projects.waitingOnly, failed = projects.filter(\.failed)
        let prs = projects.waitingPRCount
        var out = waiting.isEmpty ? L("Nothing waits.", "Nichts wartet.")
            : L("\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).",
                "\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) \(prs == 1 ? "wartet" : "warten") in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).")
        if !failed.isEmpty { out += " " + failures(failed, hideNames: hideNames) }
        return out + age(at, now: now)
    }
    /// With "Unlock on open" on, Siri and Shortcuts say numbers only: the names are behind the app lock.
    static func failures(_ failed: [PhoneProject], hideNames: Bool = false) -> String {
        if hideNames, !failed.isEmpty {
            return L("\(plural(failed.count, ("project", "Projekt"), ("projects", "Projekte"))) failed. Open the app for the names.",
                     "\(plural(failed.count, ("project", "Projekt"), ("projects", "Projekte"))) \(failed.count == 1 ? "ist" : "sind") fehlgeschlagen. Die Namen zeigt die App.")
        }
        let names = failed.prefix(5).map(\.name).joined(separator: ", ") + (failed.count > 5 ? L(" and \(failed.count - 5) more", " und \(failed.count - 5) weitere") : "")
        return failed.isEmpty ? L("Nothing failed.", "Nichts ist fehlgeschlagen.")
            : L("Failed: \(names).", "Fehlgeschlagen: \(names).")
    }
    static func age(_ at: Date?, now: Date = Date()) -> String {
        guard let at else { return "" }
        let rel = at.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: appLocale))
        return L(" As of \(rel); open the app for the newest state.", " Stand \(rel); die App zeigt den neuesten.")
    }
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await MainActor.run {
            guard let l = Spoken.last() else { return L("Nothing read yet: open Deploy Center once.", "Noch nichts gelesen: öffne Deploy Center einmal.") }
            return Spoken.waiting(l.projects, at: l.at, hideNames: PhoneStore.lockOnOpen)
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
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
