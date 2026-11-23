// Deploy Center — The menu bar's counter ("5 waiting, 2 failed") and its mini list.

import Foundation

enum MenuBarSummary {
    /// "5 waiting, 2 failed", "3 waiting", "1 failed"; nil when there is nothing to say.
    static func text(waiting: Int, failed: Int) -> String? {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? L("1 waiting", "1 wartet") : L("\(waiting) waiting", "\(waiting) warten")) }
        if failed > 0 { parts.append(L("\(failed) failed", "\(failed) fehlgeschlagen")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Rows whose newest deploy failed, not hidden, a running one not counted, newest first.
    static func failed(_ items: [Item], hidden: (Item) -> Bool) -> [Item] {
        items.filter { Row.keyFigure($0) == .failed && !$0.state.isActive && !hidden($0) }
            .sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
    }
}
