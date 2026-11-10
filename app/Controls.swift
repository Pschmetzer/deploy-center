// Deploy Center — Small controls used in several views.

import SwiftUI
import AppKit

/// Puts text on the clipboard and says so for a moment ("Copied ✓"), so a click is not a guess.
struct CopyButton: View {
    let title: String
    var systemImage: String? = nil
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } label: {
            if let systemImage {
                Image(systemName: copied ? "checkmark" : systemImage)
            } else {
                Text(copied ? L("Copied ✓", "Kopiert ✓") : title)
            }
        }
        .help(title)
        .accessibilityLabel(copied ? L("Copied", "Kopiert") : title)
    }
}
