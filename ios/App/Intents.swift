// Deploy Center for iPhone — Siri, Shortcuts and Spotlight: read-only questions about the last state read.
// No deploy here: a deploy asks for Face ID in the app, and a voice command is no place for that.

import AppIntents
import Foundation

enum Spoken {
    /// One answer for "what waits": PRs and projects waiting, failures by name, and how old the state is.
    static func waiting(_ projects: [PhoneProject], at: Date?, now: Date = Date()) -> String {
        let waiting = projects.filter(\.changed), failed = projects.filter(\.failed)
        let prs = waiting.reduce(0) { $0 + ($1.pendingPRs ?? 0) }
        var out = waiting.isEmpty ? L("Nothing waits.", "Nichts wartet.")
            : L("\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).",
                "\(plural(prs, ("PR", "PR"), ("PRs", "PRs"))) \(prs == 1 ? "wartet" : "warten") in \(plural(waiting.count, ("project", "Projekt"), ("projects", "Projekten"))).")
        if !failed.isEmpty { out += " " + failures(failed) }
        return out + age(at, now: now)
    }
    static func failures(_ failed: [PhoneProject]) -> String {
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await MainActor.run {
            guard let l = Spoken.last() else { return L("Nothing read yet: open Deploy Center once.", "Noch nichts gelesen: öffne Deploy Center einmal.") }
            return Spoken.waiting(l.projects, at: l.at)
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct FailuresIntent: AppIntent {
    static let title: LocalizedStringResource = "Failed deploys"
    static let description = IntentDescription("Which projects failed, from the state Deploy Center read last.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = await MainActor.run {
            guard let l = Spoken.last() else { return L("Nothing read yet: open Deploy Center once.", "Noch nichts gelesen: öffne Deploy Center einmal.") }
            return Spoken.failures(l.projects.filter(\.failed)) + Spoken.age(l.at)
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
    private static var indexed: [String] = []

    /// Project names in Spotlight, opening the project. Demo projects are not indexed; only when the list changed.
    @MainActor static func index(_ projects: [PhoneProject], demo: Bool) {
        let keys = demo ? [] : projects.map { $0.key + "|" + $0.name }
        guard keys != indexed else { return }
        indexed = keys
        let idx = CSSearchableIndex.default()
        idx.deleteAllSearchableItems { _ in
            guard !demo else { return }
            let items = projects.map { p in
                let a = CSSearchableItemAttributeSet(contentType: .text)
                a.title = p.name
                a.contentDescription = p.provider.rawValue + (p.domain.map { " · " + $0 } ?? "")
                return CSSearchableItem(uniqueIdentifier: p.key, domainIdentifier: "projects", attributeSet: a)
            }
            idx.indexSearchableItems(items) { _ in }
        }
    }

    /// The project key of a Spotlight hit or a handed-off activity.
    static func key(_ a: NSUserActivity) -> String? {
        if a.activityType == CSSearchableItemActionType { return a.userInfo?[CSSearchableItemActivityIdentifier] as? String }
        return a.userInfo?["project"] as? String
    }
}
