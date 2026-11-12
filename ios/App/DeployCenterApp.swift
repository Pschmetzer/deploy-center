// Deploy Center for iPhone and iPad — Entry point and the background refresh.

import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct DeployCenterApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView(store: delegate.store) }
            .backgroundTask(.appRefresh(Background.id)) {
                await Background.run()
            }
            .onChange(of: phase) { _, p in
                if p == .background { Background.schedule(); delegate.store.lockIfWanted() }
            }
            // iPad with a keyboard: ⌘R reads everything again, ⌘D deploys the selected project, ⌘, opens Settings.
            .commands { DeployCommands() }
    }
}

/// Owns the store, so a tapped notification can open its project; shows notifications in the foreground too.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = PhoneStore.shared

    /// For the scene delegate (home-screen quick actions): the one app delegate.
    static weak var current: AppDelegate?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Self.current = self
        UNUserNotificationCenter.current().delegate = self
        Notes.registerActions()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        // Started by a quick action: handled once the store exists (it does: it is made with this delegate).
        if let item = options.shortcutItem { QuickActions.handle(item, store: store) }
        return c
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["project"] as? String
        if response.actionIdentifier == Notes.muteAction { Notes.muteToday(); return }
        await MainActor.run { if let key { store.openKey = key } }
    }
}

/// Only for quick actions on the app icon while the app runs; SwiftUI keeps the window.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let store = AppDelegate.current?.store else { completionHandler(false); return }
        completionHandler(QuickActions.handle(item, store: store))
    }
}

/// Quick actions on the app icon: "Refresh", and the projects that need a look (failed first, then waiting).
@MainActor
enum QuickActions {
    static let reload = "app.deploycenter.ios.reload", open = "app.deploycenter.ios.open"

    static func update(_ projects: [PhoneProject]) {
        let look = projects.filter { $0.group != .live }.prefix(3)
        UIApplication.shared.shortcutItems = look.map { p in
            UIApplicationShortcutItem(type: open, localizedTitle: p.name, localizedSubtitle: p.stateText,
                                      icon: UIApplicationShortcutIcon(systemImageName: p.failed ? "exclamationmark.triangle" : "clock"),
                                      userInfo: ["project": p.key as NSString])
        } + [UIApplicationShortcutItem(type: reload, localizedTitle: L("Refresh", "Aktualisieren"), localizedSubtitle: nil,
                                       icon: UIApplicationShortcutIcon(systemImageName: "arrow.clockwise"), userInfo: nil)]
    }

    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem, store: PhoneStore) -> Bool {
        switch item.type {
        case reload: Task { await store.reload() }; return true
        case open:
            guard let key = item.userInfo?["project"] as? String else { return false }
            store.openKey = key; return true
        default: return false
        }
    }
}

enum Background {
    static let id = "app.deploycenter.ios.refresh"
    /// Why the last request for a background refresh failed, for Settings. Nil when it worked.
    @MainActor static var scheduleError: String?

    /// Asked at launch, when the app goes to the background and when Settings change: iOS keeps one.
    @MainActor static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        do { try BGTaskScheduler.shared.submit(r); scheduleError = nil }
        catch let e as BGTaskScheduler.Error where e.code == .unavailable {
            scheduleError = L("Background App Refresh is off for Deploy Center (or Low Power Mode is on).",
                              "Hintergrundaktualisierung ist für Deploy Center aus (oder der Stromsparmodus ist an).")
        } catch { scheduleError = error.localizedDescription }
    }

    /// iOS gives a refresh about 30 seconds; the load gets this much of it, the notes the rest.
    static let budget: Duration = .seconds(22)

    /// Reads the lists, updates the widget, and notes what newly waits or failed. No server: iOS decides when.
    /// The app's own store, so the list is fresh on return. A load that runs out of its time budget (or that
    /// iOS cancels) replaces nothing and notes nothing. Calls wait less for retries in here (HTTP.inBackground).
    @MainActor static func run() async {
        schedule()
        let store = PhoneStore.shared
        store.forgetKeptTokens()
        await store.refreshLink()   // a cold background launch has not read the Mac's keys yet
        guard !store.demo, store.hasAccount else { return }
        // Nothing seen yet (first run, or the file is gone): nothing counts as new, no flood of notes.
        let before = readLast()
        let complete = await withTaskGroup(of: Bool?.self) { g in
            g.addTask { await HTTP.$inBackground.withValue(true) { await store.reload() } }
            g.addTask { try? await Task.sleep(for: budget); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? false
        }
        guard complete, !Task.isCancelled else { return }
        if let before { await store.notifyChanges(from: before) }
    }

    /// In Application Support, not Caches: iOS may empty Caches, and then every waiting project looked new.
    static var lastURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("last-projects.json")
    }
    private static var oldLastURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("last-projects.json")
    }
    static func readLast() -> [PhoneProject]? {
        let data = (try? Data(contentsOf: lastURL)) ?? (try? Data(contentsOf: oldLastURL))
        return data.flatMap { try? JSONDecoder().decode([PhoneProject].self, from: $0) }
    }
    /// The last list with the time it was written (the file's date): for the list at launch, Siri and Spotlight.
    static func loadLast() -> (projects: [PhoneProject], at: Date)? {
        guard let p = readLast() else { return nil }
        let url = FileManager.default.fileExists(atPath: lastURL.path) ? lastURL : oldLastURL
        return (p, (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? Date())
    }
    static func writeLast(_ projects: [PhoneProject]) {
        // Application Support does not exist in a fresh sandbox.
        try? FileManager.default.createDirectory(at: lastURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(projects).write(to: lastURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.removeItem(at: oldLastURL)
    }

    /// True when notifications may be shown.
    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
