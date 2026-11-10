// Deploy Center for iPhone and iPad — Entry point and the background refresh.

import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct DeployCenterApp: App {
    @StateObject private var store = PhoneStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView(store: store) }
            .backgroundTask(.appRefresh(Background.id)) {
                await Background.run()
            }
            .onChange(of: phase) { _, p in
                if p == .background { Background.schedule(); store.lockIfWanted() }
            }
    }
}

enum Background {
    static let id = "app.deploycenter.ios.refresh"

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Reads the lists, updates the widget, and notes what newly waits or failed. No server: iOS decides when.
    /// The app's own store, so the list is fresh on return. iOS gives this about 30 seconds and then cancels
    /// the task: a cut-off load replaces nothing and notes nothing.
    @MainActor static func run() async {
        schedule()
        let store = PhoneStore.shared
        guard !store.demo, store.hasAccount else { return }
        // Nothing seen yet (first run, or the file is gone): nothing counts as new, no flood of notes.
        let before = readLast()
        guard await store.reload(), !Task.isCancelled else { return }
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
    static func writeLast(_ projects: [PhoneProject]) {
        // Application Support does not exist in a fresh sandbox.
        try? FileManager.default.createDirectory(at: lastURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(projects).write(to: lastURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.removeItem(at: oldLastURL)
    }

    /// True when notifications may be shown.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
