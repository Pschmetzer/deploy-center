// Deploy Center for iPhone and iPad — Entry point and the background refresh.

import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct DeployCenterApp: App {
    @StateObject private var store = PhoneStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView(store: store) }
            .backgroundTask(.appRefresh(Background.id)) {
                await Background.run()
            }
            .onChange(of: phase) { _, p in if p == .background { Background.schedule() } }
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
    @MainActor static func run() async {
        schedule()
        let store = PhoneStore()
        guard !store.demo, store.hasAccount else { return }
        let before = (try? Data(contentsOf: lastURL)).flatMap { try? JSONDecoder().decode([PhoneProject].self, from: $0) } ?? []
        await store.reload()
        await store.notifyChanges(from: before)
        try? JSONEncoder().encode(store.projects).write(to: lastURL, options: .atomic)
    }

    static var lastURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("last-projects.json")
    }

    /// True when notifications may be shown.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
