// Local notifications: grouped per project, actions on a note, quiet mode.

import Foundation
import UserNotifications

/// Local notifications: grouped in one thread; the same news replaces itself instead of piling up.
/// Actions on a notification: open the project, or no more news today (a deploy started here still reports its end).
enum Notes {
    static let category = "deploy-center.news"
    static let waitingCategory = "deploy-center.waiting"
    static let openAction = "open", muteAction = "mute-today", deployAction = "deploy-now"
    static let mutedKey = "notesMutedUntil"

    static func registerActions() {
        let open = UNNotificationAction(identifier: openAction, title: L("Open", "Öffnen"), options: [.foreground])
        let mute = UNNotificationAction(identifier: muteAction, title: L("Mute for today", "Heute stumm"), options: [])
        // "Deploy": opens the app (it needs the screen for Face ID) and needs the device unlocked. Face ID
        // is asked by the same path as every deploy, so a tap on the note alone starts nothing.
        let deploy = UNNotificationAction(identifier: deployAction, title: L("Deploy with Face ID", "Mit Face ID deployen"),
                                          options: [.foreground, .authenticationRequired])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [open, mute], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: L("Deploy Center news", "Neuigkeit von Deploy Center"), options: []),
            UNNotificationCategory(identifier: waitingCategory, actions: [deploy, open, mute], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: L("A project is waiting", "Ein Projekt wartet"), options: [])
        ])
    }
    /// Until the start of tomorrow, in this device's calendar.
    static func muteToday(now: Date = Date()) {
        let cal = Calendar.current
        UserDefaults.standard.set(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)), forKey: mutedKey)
    }
    static var muted: Bool { (UserDefaults.standard.object(forKey: mutedKey) as? Date).map { Date() < $0 } ?? false }

    /// Asks once, the first time a deploy is followed, when the person never answered: the end of a deploy
    /// is reported even if "Notify" in Settings was never switched on. A "no" is not asked again.
    static var needsAsk: Bool {
        get async { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined }
    }
    static func askOnce() async {
        guard await needsAsk else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(_ body: String, project: String?, id: String? = nil, news: Bool = false) async {
        if news && muted { return }
        let c = UNMutableNotificationContent()
        // With "Unlock on open" the lock screen must not name projects either (IDEEN-12 C23).
        c.title = "Deploy Center"; c.sound = .default
        c.body = UserDefaults.standard.bool(forKey: "lockOnOpen") ? L("A project has news. Open the app.", "Ein Projekt hat Neuigkeiten. App öffnen.") : body
        // One thread per project groups its history; failures rise in the notification summary, news falls.
        c.threadIdentifier = project.map { "deploy-center-" + $0 } ?? "deploy-center"
        let kind = (id ?? "").split(separator: ":").first.map(String.init) ?? ""
        c.relevanceScore = kind == "failed" ? 1.0 : kind == "waiting" ? 0.3 : kind == "recovered" ? 0.5 : kind == "live" ? 0.5 : 0.7
        // A failure may interrupt a Focus that allows it; news that something waits or is live does not (IDEEN-12 C24).
        c.interruptionLevel = kind == "failed" ? .active : .passive
        c.categoryIdentifier = (id ?? "").hasPrefix("waiting:") ? waitingCategory : category
        if let project { c.userInfo = ["project": project] }
        let r = UNNotificationRequest(identifier: id ?? "deploy-\(project ?? "")", content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(r)
    }
}
