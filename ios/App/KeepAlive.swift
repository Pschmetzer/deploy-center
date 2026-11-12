// Deploy Center for iPhone — More time to follow a deploy after the app goes to the background.
// iOS suspends an app soon after the screen locks. A background task buys about half a minute; on
// iOS 26 a continued processing task keeps going with a progress the system shows, until the deploy
// ends or iOS stops it. Neither is promised: the end also comes as a notification, and opening the
// app reads the state again.

import BackgroundTasks
import UIKit

@MainActor
final class KeepAlive {
    /// The prefix of the wildcard in BGTaskSchedulerPermittedIdentifiers (ios/Config/Info.plist).
    static let prefix = "app.deploycenter.ios.follow."

    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?     // BGContinuedProcessingTask on iOS 26
    private var title = ""
    private var ended = false

    static func start(title: String, subtitle: String) -> KeepAlive {
        let k = KeepAlive()
        k.title = title
        k.bgTask = UIApplication.shared.beginBackgroundTask(withName: "follow-deploy") { [weak k] in
            // UIKit calls this on the main thread, and the task must end before it returns.
            MainActor.assumeIsolated { k?.endBackgroundTask() }
        }
        if #available(iOS 26, *) { k.submitContinued(subtitle) }
        return k
    }

    @available(iOS 26, *)
    private func submitContinued(_ subtitle: String) {
        // One identifier per follow: a handler can be registered only once per identifier.
        let id = Self.prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                guard let self, !self.ended else { t.setTaskCompleted(success: true); return }
                t.progress.totalUnitCount = 100
                // May run on any thread: complete right here, then tidy up on the main actor.
                t.expirationHandler = { [weak self] in
                    t.setTaskCompleted(success: false)
                    Task { @MainActor in self?.continued = nil }
                }
                self.continued = t
            }
        }
        guard registered else { return }
        let r = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        r.strategy = .fail     // only now, while the person waits for it, never queued for later
        try? BGTaskScheduler.shared.submit(r)
    }

    /// The state in words and a rough share of a typical build, for the system's progress.
    func update(_ state: String, fraction: Double) {
        if #available(iOS 26, *), let t = continued as? BGContinuedProcessingTask {
            t.updateTitle(title, subtitle: state)
            t.progress.completedUnitCount = Int64(max(0, min(fraction, 1)) * 100)
        }
    }

    func finish(success: Bool) {
        ended = true
        if #available(iOS 26, *), let t = continued as? BGContinuedProcessingTask {
            t.progress.completedUnitCount = 100
            t.setTaskCompleted(success: success)
        }
        continued = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}
