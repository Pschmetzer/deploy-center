// Deploy Center — The colour a person gives a project (row menu "Colour"): one list for the
// stored names, the dot on the row and the menu's words.

import SwiftUI

enum ProjectColor: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    /// Any stored or unknown name reads as gray, so an old value never breaks a row.
    init(name: String) { self = ProjectColor(rawValue: name) ?? .gray }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    var label: String {
        switch self {
        case .red: return L("Red", "Rot")
        case .orange: return L("Orange", "Orange")
        case .yellow: return L("Yellow", "Gelb")
        case .green: return L("Green", "Grün")
        case .blue: return L("Blue", "Blau")
        case .purple: return L("Purple", "Lila")
        case .gray: return L("Gray", "Grau")
        }
    }
}
