// Deploy Center — The words of the widgets in the right language. Shared so ios/test.sh can check them.

import Foundation

/// The words in the app's language: the one the snapshot names (Mac: Settings → Language; iPhone: the
/// app's language), read once per entry; without one, the system's.
struct Words {
    let german: Bool
    init(_ snap: DeploySnapshot?) {
        german = DeploySnapshot.localized(snap?.language, "en", "de") == "de"
    }
    init(german: Bool) { self.german = german }
    func callAsFunction(_ en: String, _ de: String) -> String { german ? de : en }
    func n(_ n: Int, _ one: (String, String), _ many: (String, String)) -> String {
        "\(n) " + (n == 1 ? self(one.0, one.1) : self(many.0, many.1))
    }
    /// After this long without a new snapshot the numbers are greyed and marked as old.
    static let staleAfter: TimeInterval = 3 * 3600
}
