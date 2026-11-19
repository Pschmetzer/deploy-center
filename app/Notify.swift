// Deploy Center — Mac notifications: when a deploy ends, reminders and alarms.

import SwiftUI
import AppKit
import UserNotifications

/// A Mac notification when a deploy ends while the window is in the background.
/// Permission is asked at the first deploy, when a reminder is turned on, or – if neither came first –
/// when the first alarm (stale commits, budget) is due, which may be while the window is in the
/// background. macOS asks the person only once.
/// An ad-hoc build may be refused; then nothing shows.
@MainActor
enum Notify {
    /// Notifications need an app bundle; a bare binary (the tests) would crash asking for them.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }
    static func ask(then: (@Sendable (Bool) -> Void)? = nil) {
        guard available else { then?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in then?(granted) }
    }
    /// A reminder the person set up themselves: shown whether or not the window is in front.
    /// Quiet hours hold it back too. `then` (main actor) gets whether the notification was really
    /// handed to the system, so a caller marks it as sent only then.
    static func remind(_ title: String, _ body: String, id: String = NotifyRouter.reminderId, then: (@MainActor (Bool) -> Void)? = nil) {
        let d = UserDefaults.standard
        guard available, !quiet(hour: Calendar.current.component(.hour, from: Date()), from: d.integer(forKey: "quietFrom"), to: d.integer(forKey: "quietTo")) else {
            then?(false); return
        }
        add(title, body, id: id, then: then)
    }
    /// One authorization request at a time: two alarms at once would ask twice.
    private static var authorization: Task<Bool, Never>?
    private static func authorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            if let t = authorization { return await t.value }
            let t = Task { (try? await center.requestAuthorization(options: [.alert, .sound])) == true }
            authorization = t
            let ok = await t.value
            authorization = nil
            return ok
        default: return false
        }
    }
    /// `project`: a click on it shows that project in the window. `key` (Store.key) with `failed`:
    /// the notification has "Show log" (and with `rollBack`, a live site that is broken, "Roll back …"),
    /// which open the window there; nothing runs by itself.
    /// `autoOn` with `key`: auto-deploy came back on; the notification offers "Turn off".
    static func post(_ title: String, _ body: String, project: String? = nil, key: String? = nil, failed: Bool = false, rollBack: Bool = false, autoOn: Bool = false, silent: Bool = false) {
        let d = UserDefaults.standard
        guard available, !windowInFront, d.object(forKey: "notifications") as? Bool ?? true else { return }
        // Quiet hours (Settings → Notifications): only failures still come.
        let inQuiet = quiet(hour: Calendar.current.component(.hour, from: Date()), from: d.integer(forKey: "quietFrom"), to: d.integer(forKey: "quietTo"))
        if !failed, inQuiet {
            // Kept, and delivered as one note when the quiet hours end (the same id replaces the earlier note).
            let held = QuietDigest.adding(title + (body.isEmpty ? "" : ": " + body), to: d.stringArray(forKey: QuietDigest.key) ?? [])
            d.set(held, forKey: QuietDigest.key)
            let n = QuietDigest.note(held, neutral: d.bool(forKey: "neutralNotifications"))
            add(n.title, n.body, id: QuietDigest.id, after: QuietDigest.seconds(until: d.integer(forKey: "quietTo")))
            return
        }
        // Outside the quiet hours the earlier note has been delivered: start the next night empty.
        if !inQuiet, d.object(forKey: QuietDigest.key) != nil { d.removeObject(forKey: QuietDigest.key) }
        // Settings → General: a notification on the lock screen says that something happened, not which project.
        let neutral = d.bool(forKey: "neutralNotifications")
        let title = neutral ? (failed ? L("A deploy needs a look", "Ein Deploy braucht einen Blick") : L("Deploy Center", "Deploy Center")) : title
        let body = neutral ? L("Open Deploy Center for details.", "Details im Deploy Center.") : body
        let category = autoOn && key != nil ? NotifyRouter.autoOnCategory
            : failed && key != nil ? (rollBack ? NotifyRouter.brokenCategory : NotifyRouter.failedCategory) : nil
        add(title, body, id: UUID().uuidString, category: category, project: project, key: key, silent: silent)
        // A failure nobody looked at comes back once, 30 minutes later (Settings), unless the app was opened.
        if failed, let key, d.bool(forKey: "remindFailures") {
            add(L("Still failing: ", "Immer noch fehlgeschlagen: ") + title, body, id: escalationPrefix + key,
                category: category, project: project, key: key, after: 30 * 60)
        }
    }
    /// The person is looking at the app: active and a visible, key window (not just the app being frontmost in the menu bar).
    static var windowInFront: Bool {
        guard NSApp.isActive, let w = NSApp.keyWindow else { return false }
        return w.isVisible && !w.isMiniaturized
    }
    /// Whether a `post` that is not a failure would show now (the window in the background, the
    /// switch on, outside quiet hours).
    static var wouldShow: Bool {
        let d = UserDefaults.standard
        return available && !windowInFront && d.object(forKey: "notifications") as? Bool ?? true
            && !quiet(hour: Calendar.current.component(.hour, from: Date()), from: d.integer(forKey: "quietFrom"), to: d.integer(forKey: "quietTo"))
    }
    static let escalationPrefix = "again|"
    static let soundsKey = "resultSounds"
    /// The second reminders that wait: gone once the person is back in the app, or the project ran again.
    static func dropEscalations(_ key: String? = nil) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if let key { center.removePendingNotificationRequests(withIdentifiers: [escalationPrefix + key]); return }
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix(escalationPrefix) })
        }
    }
    /// Whether `hour` (0–23) is inside quiet hours from `from` to `to` (both 0: off). 22 to 7 runs over midnight.
    nonisolated static func quiet(hour: Int, from: Int, to: Int) -> Bool {
        guard from != to else { return false }
        return from < to ? (from..<to).contains(hour) : (hour >= from || hour < to)
    }
    /// The countdown before an automatic rollback: shown even with the window in front, with Cancel.
    static func countdown(_ title: String, _ body: String, id: String) {
        add(title, body, id: id, category: NotifyRouter.rollbackCategory)
    }
    static func remove(_ id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
    /// Asks first only when the person was never asked, so the first alarm of a run is not lost.
    private static func add(_ title: String, _ body: String, id: String, category: String? = nil, project: String? = nil,
                            key: String? = nil, after: TimeInterval? = nil, silent: Bool = false,
                            then: (@MainActor (Bool) -> Void)? = nil) {
        guard available else { then?(false); return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await authorized() else { then?(false); return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body
            // A deploy's end with the result sounds on already rang once.
            c.sound = silent ? nil : .default
            if let category { c.categoryIdentifier = category }
            // A broken production and the rollback countdown must get through a Focus mode.
            if category == NotifyRouter.brokenCategory || category == NotifyRouter.rollbackCategory { c.interruptionLevel = .timeSensitive }
            var info: [String: String] = [:]
            if let project { info["project"] = project }
            if let key { info["key"] = key }
            c.userInfo = info
            // Many deploys ending together are one stack in Notification Center, not a wall.
            if category != NotifyRouter.rollbackCategory && id != NotifyRouter.reminderId { c.threadIdentifier = "deploys" }
            let trigger = after.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
            do { try await center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger)); then?(true) }
            catch { then?(false) }
        }
    }
}

/// The Cancel button of the rollback countdown, and the countdown shown while the app is in front.
/// Other notifications behave as before: not shown while the app is in front.
final class NotifyRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotifyRouter()
    static let rollbackCategory = "rollback-countdown"
    /// The daily reminder: the person asked for it, so it shows with the app in front too.
    static let reminderId = "daily-reminder"
    static func showsInFront(_ n: UNNotificationRequest) -> Bool {
        n.content.categoryIdentifier == rollbackCategory || n.identifier == reminderId
    }
    static let cancelAction = "cancel-rollback"
    static let failedCategory = "deploy-failed"
    static let brokenCategory = "live-broken"
    static let logAction = "show-log"
    static let rollbackAction = "ask-rollback"
    static let autoOnCategory = "auto-on-again"
    static let autoOffAction = "auto-off"
    /// "Show log" / "Roll back …" of a failure, with the project's key: the window opens there.
    var onAction: (@MainActor (_ action: String, _ key: String) -> Void)?
    /// Gets the notification's id when Cancel is clicked.
    var onCancel: (@MainActor (String) -> Void)?
    /// A click on the notification itself, with the project it names (if any).
    var onOpen: (@MainActor (String?) -> Void)?

    func install() {
        let center = UNUserNotificationCenter.current()
        let cancel = UNNotificationAction(identifier: Self.cancelAction, title: L("Cancel", "Abbrechen"), options: [])
        let log = UNNotificationAction(identifier: Self.logAction, title: L("Show log", "Log zeigen"), options: [.foreground])
        let back = UNNotificationAction(identifier: Self.rollbackAction, title: L("Roll back …", "Zurückrollen …"), options: [.foreground])
        let off = UNNotificationAction(identifier: Self.autoOffAction, title: L("Turn off", "Ausschalten"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.rollbackCategory, actions: [cancel],
                                                                 intentIdentifiers: [], options: []),
                                          UNNotificationCategory(identifier: Self.failedCategory, actions: [log],
                                                                 intentIdentifiers: [], options: []),
                                          UNNotificationCategory(identifier: Self.brokenCategory, actions: [log, back],
                                                                 intentIdentifiers: [], options: []),
                                          UNNotificationCategory(identifier: Self.autoOnCategory, actions: [off],
                                                                 intentIdentifiers: [], options: [])])
        center.delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.showsInFront(notification.request) ? [.banner, .sound] : [])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == Self.cancelAction { Task { @MainActor in self.onCancel?(id) } }
        else if [Self.logAction, Self.rollbackAction, Self.autoOffAction].contains(response.actionIdentifier), let key = info["key"] as? String {
            let a = response.actionIdentifier
            Task { @MainActor in self.onAction?(a, key) }
        }
        else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let project = response.notification.request.content.userInfo["project"] as? String
            Task { @MainActor in self.onOpen?(project) }
        }
        completionHandler()
    }
}
