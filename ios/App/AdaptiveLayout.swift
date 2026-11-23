// Deploy Center for iPhone and iPad — Which layout the text size asks for. Pure logic (no SwiftUI), so ios/Tests can check it:
// the steps follow Dynamic Type, and a larger text never gets a layout that is tighter than a smaller one.

import Foundation

enum AdaptiveLayout {
    /// The Dynamic Type sizes in order (the same order as SwiftUI's DynamicTypeSize).
    enum TextScale: Int, Comparable, CaseIterable {
        case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
        case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5
        static func < (a: TextScale, b: TextScale) -> Bool { a.rawValue < b.rawValue }
        var isAccessibility: Bool { self >= .accessibility1 }
    }

    /// The four numbers above the list.
    enum SummaryStyle: Int, Comparable {
        case row, grid, column   // four in a row, two rows of two, one column
        static func < (a: SummaryStyle, b: SummaryStyle) -> Bool { a.rawValue < b.rawValue }
    }

    /// Four in a row get too tight from the largest standard size on (two by two then); at accessibility sizes even two side by side do not fit.
    static func summary(_ s: TextScale) -> SummaryStyle {
        s.isAccessibility ? .column : s >= .xxxLarge ? .grid : .row
    }

    /// A line with a name on the left and a time on the right: side by side while both fit, else the time goes under the name.
    static func timeBesideName(_ s: TextScale) -> Bool { s < .accessibility1 }

    /// How many lines a title may take: one for the standard sizes (a truncated title is still readable), more where the size is large
    /// and there is room, never a cut-off of what the person came to read at accessibility sizes.
    static func titleLines(_ s: TextScale) -> Int? { s >= .accessibility1 ? nil : s >= .xxxLarge ? 2 : 1 }
}
