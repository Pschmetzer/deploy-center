// Deploy Center — updates via Sparkle 2. Sparkle reads the feed named in Info.plist (SUFeedURL,
// https://deploycenter.app/appcast.xml), downloads the zip from GitHub, accepts it only with a valid
// EdDSA signature (SUPublicEDKey) and the same Developer ID, then swaps the app and restarts it.
// The framework is fetched and embedded by build.sh; the tests leave this file out (no -F there).

import Foundation
import Combine
import Sparkle

@MainActor
final class SoftwareUpdate: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SoftwareUpdate()

    /// False while a check or an install is under way (the menu item greys out).
    @Published private(set) var canCheck = false
    /// Set by the app: deploys queued or building. A restart for an update waits until this is false.
    var isBusy: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController!
    private var watch: AnyCancellable?

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // The old daily check had its own switch ("checkUpdates"); it still decides, so Sparkle never asks again.
        controller.updater.automaticallyChecksForUpdates = Updater.automaticChecks(UserDefaults.standard.object(forKey: "checkUpdates"))
        controller.startUpdater()
        watch = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
    }

    /// "Check for Updates …": Sparkle shows what it found, or that this is the newest version.
    func check() { controller.checkForUpdates(nil) }

    /// The switch in Settings.
    func setAutomatic(_ on: Bool) { controller.updater.automaticallyChecksForUpdates = on }

    // MARK: SPUUpdaterDelegate

    /// Never quit in the middle of deploys: Sparkle waits, and installs once they are done.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard Updater.postponeRestart(busy: isBusy()) else { return false }
            Log.write("update \(item.displayVersionString): waiting for running deploys")
            Task { @MainActor [weak self] in
                while self?.isBusy() == true { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                installHandler()
            }
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        // "No update" is not an error worth a log line.
        guard !(e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)) else { return }
        Log.write("update failed: \(e.localizedDescription)")
    }
}
