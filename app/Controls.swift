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

/// Hands the NSWindow a SwiftUI view sits in to `configure`, once it is in one (sheets, Settings).
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { Probe(configure) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let configure: (NSWindow) -> Void
        init(_ configure: @escaping (NSWindow) -> Void) { self.configure = configure; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }
    }
}
