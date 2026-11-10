// Deploy Center — Small controls used in several views.

import SwiftUI
import AppKit

/// Opens Settings when the store asks (Store.openSettings(tab:)), for code that is not a view.
struct OpensSettingsOnRequest: ViewModifier {
    @ObservedObject var store: Store
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onChange(of: store.settingsRequest) { openSettings() }
    }
}

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
            // VoiceOver hears it too, not only the changed label.
            AccessibilityNotification.Announcement(L("Copied", "Kopiert")).post()
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

/// "1 project", "3 projects": the number with the word that fits it. In both languages:
/// `L(plural(n, "project", "projects"), plural(n, "Projekt", "Projekte"))`.
func plural(_ n: Int, _ one: String, _ other: String) -> String { "\(n) " + (n == 1 ? one : other) }

/// An error under a setting: a symbol as well as the colour, so it does not rely on red alone.
struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}

/// A platform's name as the window's tabs say it ("Cloudflare Pages", not "Cloudflare"), from a
/// script code like "render"; "all" and unknown codes are spelled out.
func providerLabel(_ id: String) -> String {
    let l = id.lowercased()
    if l == "all" { return L("All", "Alle") }
    return (ProviderInfo.builtIn + ProviderInfo.comingSoon).first { $0.id == l }?.label ?? id.capitalized
}

/// A code from the script the app does not know yet (a newer script): readable, not raw, and noted
/// in the log once, so it can be added.
func unknownCode(_ code: String, _ kind: String) -> String {
    UnknownCodes.note(kind, code)
    return L("Unknown \(kind): \(code)", "Unbekannt (\(kind)): \(code)")
}
private enum UnknownCodes {
    nonisolated(unsafe) static var seen = Set<String>()
    static func note(_ kind: String, _ code: String) {
        guard seen.insert(kind + ":" + code).inserted else { return }
        Log.write("unknown \(kind) code from the script: \(code)")
    }
}
