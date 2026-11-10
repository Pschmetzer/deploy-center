// Deploy Center — where the app comes from. Updates themselves are Sparkle's work (SoftwareUpdate.swift):
// it reads https://deploycenter.app/appcast.xml, checks the EdDSA signature and Apple's code signature,
// and swaps the app. This file has no Sparkle in it, so the tests can compile it without the framework.

import Foundation

enum Updater {
    static let repo = "Pschmetzer/deploy-center"
    static let bundleID = "app.deploycenter.mac"
    static let feed = "https://deploycenter.app/appcast.xml"
    static var runningVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// The old daily check had its own switch ("checkUpdates"); it still decides, on by default.
    static func automaticChecks(_ stored: Any?) -> Bool { stored as? Bool ?? true }
    /// Sparkle's restart waits while deploys are queued or building; a check without them goes on.
    static func postponeRestart(busy: Bool) -> Bool { busy }
}
