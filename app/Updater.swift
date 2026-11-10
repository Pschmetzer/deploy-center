// Deploy Center — where the app comes from. Updates themselves are Sparkle's work (SoftwareUpdate.swift):
// it reads https://deploycenter.app/appcast.xml, checks the EdDSA signature and Apple's code signature,
// and swaps the app. This file has no Sparkle in it, so the tests can compile it without the framework.

import Foundation

enum Updater {
    static let repo = "Pschmetzer/deploy-center"
    static let bundleID = "app.deploycenter.mac"
    static let feed = "https://deploycenter.app/appcast.xml"
    static var runningVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
