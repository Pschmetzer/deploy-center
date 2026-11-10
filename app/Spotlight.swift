// Deploy Center — Project names in Spotlight (FEA-125), opt-in in Settings → General. Only the
// name and the platform, never in demo mode; a hit opens the window with that project found.

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
enum Spotlight {
    static let key = "spotlightProjects"
    static let domain = "projects"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
    /// What was handed to Spotlight last, so an unchanged list is not indexed again.
    private static var last: [String]?

    /// The entries Spotlight gets: key, name, platform; sorted, so the comparison is stable.
    nonisolated static func entries(_ items: [(key: String, name: String, platform: String)]) -> [String] {
        items.map { "\($0.key)\t\($0.name)\t\($0.platform)" }.sorted()
    }

    static func update(_ items: [Item]) {
        // A bare binary (the tests) has no index of its own.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let index = CSSearchableIndex.default()
        guard on, !Demo.on else {
            if last != [] { index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in } }
            last = []
            return
        }
        let list = entries(items.map { (Store.key($0), $0.name, $0.platform.rawValue) })
        guard list != last else { return }
        last = list
        let found = list.map { line -> CSSearchableItem in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let a = CSSearchableItemAttributeSet(contentType: .content)
            a.title = p[1]; a.contentDescription = p[2] + " · Deploy Center"
            return CSSearchableItem(uniqueIdentifier: p[0], domainIdentifier: domain, attributeSet: a)
        }
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in index.indexSearchableItems(found) { _ in } }
    }
}
