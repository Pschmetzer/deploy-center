// Deploy Center — deploycenter:// links that only look: show a project, open its build log. A link never ticks,
// queues or starts anything, since any web page could open one.

import Foundation

enum DeepLink {
    enum Kind: Equatable { case select, log }
    /// `deploycenter://select?project=name` and `deploycenter://log?project=name` (`platform:name` works too); nil for anything else.
    static func action(_ url: URL) -> (kind: Kind, project: String)? {
        guard url.scheme == "deploycenter" else { return nil }
        let kind: Kind
        switch url.host { case "select"?: kind = .select; case "log"?: kind = .log; default: return nil }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (kind, value)
    }
}
