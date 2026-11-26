// Deploy Center for iPhone — Text colors that keep 4.5:1 on white (WCAG AA); Foundation only, so ios/test.sh holds the claim.

import Foundation

enum Contrast {
    struct RGB: Equatable { let r: Double, g: Double, b: Double }
    /// Light-mode text colors. The system red, green and blue reach only about 3.6, 2.2 and 4.0 against white;
    /// in dark mode the system colors are used (they pass on black).
    static let warning = RGB(r: 0.62, g: 0.30, b: 0)
    static let error = RGB(r: 0.75, g: 0.10, b: 0.10)
    static let success = RGB(r: 0, g: 0.45, b: 0.15)
    static let active = RGB(r: 0, g: 0.35, b: 0.85)

    private static func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
    /// The WCAG contrast ratio, 1 to 21.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static let white = RGB(r: 1, g: 1, b: 1)
}
