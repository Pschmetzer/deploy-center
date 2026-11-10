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
            .onChange(of: phase) { _, p in if p == .background { Background.schedule() } }
            .commands {
                // iPad with a keyboard: ⌘R reads everything again.
                CommandGroup(after: .newItem) {
                    Button(L("Refresh", "Aktualisieren")) { Task { await delegate.store.reload() } }
                        .keyboardShortcut("r")
                }
            }
    }
}

/// Owns the store, so a tapped notification can open its project; shows notifications in the foreground too.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = PhoneStore()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["project"] as? String
        await MainActor.run { if let key { store.openKey = key } }
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

    /// Reads the lists, updates the widget, and notes what newly waits or failed. No server: iOS decides when.
    @MainActor static func run() async {
        schedule()
        let store = PhoneStore()
        await store.refreshLink()
        guard !store.demo, store.hasAccount else { return }
        let before = loadLast()?.projects ?? []
        await store.reload()
        guard !Task.isCancelled else { return }
        await store.notifyChanges(from: before)
    }

    /// Application Support, not Caches: iOS empties Caches when space runs low, and the next run would
    /// then report every waiting project as new. Readable after the first unlock, for this refresh.
    static var lastURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-projects.json")
    }
    private static var oldURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("last-projects.json")
    }

    static func saveLast(_ projects: [PhoneProject]) {
        guard let d = try? JSONEncoder().encode(projects) else { return }
        try? d.write(to: lastURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadLast() -> (projects: [PhoneProject], at: Date)? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: lastURL.path), fm.fileExists(atPath: oldURL.path) { try? fm.moveItem(at: oldURL, to: lastURL) }
        guard let d = try? Data(contentsOf: lastURL), let p = try? JSONDecoder().decode([PhoneProject].self, from: d) else { return nil }
        let at = (try? fm.attributesOfItem(atPath: lastURL.path)[.modificationDate]) as? Date ?? Date()
        return (p, at)
    }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
