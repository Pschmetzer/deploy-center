// Version and diagnosis text of the iPhone app (no key, no project name).

import Foundation
import UIKit

extension PhoneStore {
    /// "0.11.0 (42)".
    var versionText: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// What helps to find a problem: version, system, language, which accounts are connected, how many projects.
    /// No key, no project name, no domain.
    var diagnostics: String {
        func yes(_ b: Bool) -> String { b ? "yes" : "no" }
        return [
            "Deploy Center for iPhone \(versionText)",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")",
            "Language: \(appIsGerman ? "de" : "en")",
            "Vercel key: \(yes(token(.vercel) != nil)), Render key: \(yes(token(.render) != nil)), GitHub token: \(yes(token(.github) != nil))",
            "Keys from the Mac: \(yes(linked != nil && !ignoreLink))",
            "Projects: \(projects.count), offline: \(yes(offline)), key refused: \(yes(keyRefused)), errors: \(errors.count)",
        ].joined(separator: "\n")
    }

    /// A new issue on GitHub with the diagnosis filled in.
    var reportURL: URL? {
        var c = URLComponents(string: "https://github.com/Pschmetzer/deploy-center/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "iPhone app: "),
                         URLQueryItem(name: "body", value: "What happened:\n\n\n---\n" + diagnostics)]
        return c?.url
    }
}
