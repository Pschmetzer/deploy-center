// The bridge from SwiftUI's Dynamic Type size to the pure rules in AdaptiveLayout.swift.

import SwiftUI

extension AdaptiveLayout.TextScale {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .xSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .xLarge
        case .xxLarge: self = .xxLarge
        case .xxxLarge: self = .xxxLarge
        case .accessibility1: self = .accessibility1
        case .accessibility2: self = .accessibility2
        case .accessibility3: self = .accessibility3
        case .accessibility4: self = .accessibility4
        case .accessibility5: self = .accessibility5
        @unknown default: self = .large
        }
    }
}
