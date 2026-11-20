// Deploy Center — Small controls used in several views.

import SwiftUI
import AppKit

extension View {
    /// A small icon button still gets a target of about 24 pt (the glyph stays small).
    func hitArea() -> some View { self.frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
}

/// The language the app shows, as a Locale: dates and times follow it, not only the Mac's region.
var uiLocale: Locale { Locale(identifier: isGerman ? "de_DE" : "en_US") }
/// "9:12 AM" / "09:12", in the app's language.
func uiTime(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(uiLocale)) }
/// "5:00 AM" / "05:00" for a whole hour.
func uiHour(_ h: Int) -> String {
    let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
    return uiTime(d)
}

/// A number with the decimal mark of the app's language ("12,5" in German), not the C locale's point.
func decimal(_ v: Double, _ digits: Int = 1) -> String {
    v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: isGerman ? "de_DE" : "en_US")))
}

/// Links that came out of the script's JSON or a model open only as web pages: no file:, no custom schemes.
enum SafeLink {
    nonisolated static func ok(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased(), !host.isEmpty else { return false }
        switch u.scheme?.lowercased() {
        case "https": return true
        // Every platform and GitHub link is https; plain http only for a project on this Mac.
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1" || host.hasSuffix(".localhost")
        default: return false
        }
    }
    @MainActor static func open(_ u: URL) { if ok(u) { NSWorkspace.shared.open(u) } }
}

/// Opens Settings when the store asks (Store.openSettings), for code that is not a view; also from
/// the menu bar, where no main window may be open.
/// The main window too, when a notification was clicked (Store.windowRequest).
struct OpensSettingsOnRequest: ViewModifier {
    @ObservedObject var store: Store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .onChange(of: store.settingsRequest) { _, tab in
                guard tab != nil else { return }
                store.settingsRequest = nil
                NSApp.activate(ignoringOtherApps: true); openSettings()
            }
            .onChange(of: store.windowRequest) { openWindow(id: "main") }
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
            Pasteboard.copy(text())
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
    return ProviderInfo.label(for: l)   // the names the script told, then the known ones
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
