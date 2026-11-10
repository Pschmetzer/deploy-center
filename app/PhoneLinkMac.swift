// Deploy Center — Settings → iPhone: hands this Mac's keys to the iPhone app.
// Through iCloud Keychain (shared/PhoneLink.swift) when this build carries the keychain group,
// or as a QR code shown for a minute. Keys are read from where `deploys` keeps them, through
// pipes, never as arguments, and never written to the log.

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

@MainActor
final class PhoneLinkModel: ObservableObject {
    static let shared = PhoneLinkModel()
    @Published var lastPush: Date?
    @Published var problem: String?
    @Published var busy = false

    var on: Bool { UserDefaults.standard.bool(forKey: "phoneLink") }
    /// The saving a month from the costs (Store.savingPerMonth), handed to the phone with the keys.
    private(set) var savingPerMonth: Double?
    /// A new figure goes out with the keys; the same one writes nothing.
    func update(savingPerMonth v: Double?) {
        guard v != savingPerMonth else { return }
        savingPerMonth = v
        Task { await pushIfOn() }
    }
    var available: Bool { PhoneLink.group != nil }

    /// At launch and after each change in Settings.
    func pushIfOn() async { if on && available { await push() } }
    /// At launch and then once a day: keys that changed on the Mac reach the phone.
    func pushIfStale() async {
        if let t = lastPush, Date().timeIntervalSince(t) < 24 * 3600 { return }
        await pushIfOn()
    }
    /// The gh CLI's token can usually write (repo, workflow); the phone only reads. Off by default.
    nonisolated static let githubKey = "phoneLinkGitHub"

    func push() async {
        busy = true; defer { busy = false }
        var keys = await Self.collect()
        keys.savingPerMonth = savingPerMonth
        guard !keys.isEmpty else {
            problem = L("No Vercel token for the iPhone and no Render key on this Mac yet.",
                        "Noch kein Vercel-Token fürs iPhone und kein Render-Key auf diesem Mac.")
            return
        }
        let s = PhoneLink.write(keys)
        if s == errSecSuccess { lastPush = Date(); problem = nil }
        else {
            problem = L("Could not write to iCloud Keychain (error \(s)).", "Konnte nicht in den iCloud-Schlüsselbund schreiben (Fehler \(s)).")
            Log.write("phone link: SecItemAdd \(s)")
        }
    }

    func turnOff() {
        PhoneLink.remove(); lastPush = nil; problem = nil
    }

    /// The keys as the phone needs them. Vercel: the token made for the phone (the vercel CLI's own
    /// login is short-lived). Render: the key `deploys` uses. GitHub: the gh CLI's token, if any.
    nonisolated static func collect() async -> LinkedKeys {
        var k = LinkedKeys()
        k.vercel = MacSecret.get("deploy-center-phone-vercel") ?? ""
        let teamFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys/vercel-team")
        k.vercelTeam = ((try? String(contentsOf: teamFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        k.render = output("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-s", "deploy-center-render", "-w"])
            ?? output("/usr/bin/security", ["find-generic-password", "-a", NSUserName(), "-s", "render-api-key", "-w"]) ?? ""
        // Only when asked for (Settings → iPhone): the gh token's scopes are wider than the phone needs.
        if UserDefaults.standard.bool(forKey: githubKey) { k.github = output("/usr/bin/env", ["gh", "auth", "token"]) ?? "" }
        k.updated = Date()
        return k
    }

    /// stdout of a command, trimmed; nil when it fails or prints nothing. Nothing is logged.
    nonisolated private static func output(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // gh or security can wait for a dialog or the network: after 10 s the key counts as missing.
        let killer = DispatchWorkItem { if p.isRunning { Tool.killTree(p.processIdentifier) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// A secret of this app in the login keychain (the app created it, so reading it asks nothing).
enum MacSecret {
    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()]
    }
    static func get(_ service: String) -> String? {
        var q = base(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
    /// Updates in place (the old token stays if writing fails); an empty value deletes.
    /// True when the keychain took it.
    @discardableResult
    static func set(_ service: String, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { SecItemDelete(base(service) as CFDictionary); return true }
        let data = Data(v.utf8)
        var status = SecItemUpdate(base(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(service); add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { Log.write("keychain: \(service) not saved (status \(status))") }
        return status == errSecSuccess
    }
}

struct PhoneLinkSettings: View {
    @ObservedObject private var link = PhoneLinkModel.shared
    @AppStorage("phoneLink") private var on = false
    @State private var vercel = ""
    @State private var hasVercel = MacSecret.get("deploy-center-phone-vercel") != nil
    @State private var qr = false
    @AppStorage(PhoneLinkModel.githubKey) private var shareGitHub = false

    var body: some View {
        Section {
            if link.available {
                Toggle(L("Connect the iPhone app (iCloud Keychain)", "Mit der iPhone-App verbinden (iCloud-Schlüsselbund)"), isOn: $on)
                    .onChange(of: on) { _, v in Task { if v { await link.push() } else { link.turnOff() } } }
            } else {
                Text(L("This build cannot use iCloud Keychain. Use the QR code.", "Dieser Build kann den iCloud-Schlüsselbund nicht nutzen. Nimm den QR-Code."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                SecureField(hasVercel ? L("Vercel token for the iPhone: saved", "Vercel-Token fürs iPhone: gespeichert")
                                      : L("Vercel token for the iPhone", "Vercel-Token fürs iPhone"), text: $vercel)
                Button(L("Save", "Sichern")) {
                    MacSecret.set("deploy-center-phone-vercel", vercel); vercel = ""
                    hasVercel = MacSecret.get("deploy-center-phone-vercel") != nil
                    Task { await link.pushIfOn() }
                }.disabled(vercel.isEmpty)
            }
            Link(L("Create a Vercel token (vercel.com → Account → Tokens)", "Vercel-Token erstellen (vercel.com → Account → Tokens)"),
                 destination: URL(string: "https://vercel.com/account/tokens")!)
            Toggle(L("Also hand over the GitHub token of the gh CLI", "Auch das GitHub-Token der gh-CLI übergeben"), isOn: $shareGitHub)
                .onChange(of: shareGitHub) { Task { await link.pushIfOn() } }
                .help(L("It can usually push code and run workflows; the iPhone app only reads commits. Off, the phone shows no commit counts.",
                        "Es darf meist Code pushen und Workflows starten; die iPhone-App liest nur Commits. Aus: das iPhone zeigt keine Commit-Zahlen."))
            Button(L("Show a QR code for the iPhone …", "QR-Code fürs iPhone zeigen …")) { qr = true }
            if let p = link.problem { ErrorText(p) }
            else if on, let t = link.lastPush {
                Text(L("Handed over ", "Übergeben ") + t.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
            }
        } header: { Text("iPhone") } footer: {
            Text(L("The iPhone app gets the keys of this Mac: the Vercel token above, the Render key and, if you turn it on, the GitHub token of the gh CLI (its scopes are wide; a fine-grained read-only token is safer). With iCloud Keychain they reach every device signed in with your Apple ID, end-to-end encrypted; there is no server of ours. Turning it off removes them there too.",
                   "Die iPhone-App bekommt die Schlüssel dieses Macs: das Vercel-Token oben, den Render-Key und, wenn eingeschaltet, das GitHub-Token der gh-CLI (es darf viel; ein fein begrenztes Nur-Lese-Token ist sicherer). Mit dem iCloud-Schlüsselbund kommen sie auf jedes Gerät mit deiner Apple-ID, Ende-zu-Ende-verschlüsselt; es gibt keinen Server von uns. Ausschalten entfernt sie dort auch."))
        }
        .sheet(isPresented: $qr) { PhoneQRSheet() }
    }
}

/// The keys as a QR code, for one minute. The phone scans it in the app (Settings → Connect to the Mac).
struct PhoneQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var empty = false
    @State private var left = 60
    /// The code is covered while Deploy Center is not the front app (someone else may look).
    @State private var inactive = false
    /// The same code as text, for "Copy code" (a phone without a camera pastes it).
    @State private var code = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text(L("Scan with the iPhone app", "Mit der iPhone-App scannen")).font(.headline)
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260)
                    .blur(radius: inactive ? 18 : 0)
                    .overlay { if inactive { Text(L("Hidden while Deploy Center is in the background", "Verdeckt, solange Deploy Center im Hintergrund ist")).font(.caption).multilineTextAlignment(.center).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)) } }
                    .accessibilityLabel(L("QR code with your keys – show it to no one", "QR-Code mit deinen Schlüsseln – zeig ihn niemandem"))
                Text(L("Deploy Center on the iPhone → Connect to the Mac → Scan the code. This code holds your keys: show it to no one. It closes in \(left) s.",
                       "Deploy Center auf dem iPhone → Mit dem Mac verbinden → Code scannen. Dieser Code enthält deine Schlüssel: zeig ihn niemandem. Er schließt in \(left) s."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 300)
            } else if empty {
                Text(L("No keys to hand over yet: save a Vercel token for the iPhone or set up Render first.",
                       "Noch keine Schlüssel zum Übergeben: zuerst ein Vercel-Token fürs iPhone sichern oder Render einrichten."))
                    .frame(width: 300)
            } else { ProgressView() }
            HStack {
                if image != nil {
                    // Universal Clipboard takes it to the iPhone; it is cleared again when the code closes.
                    Button(copied ? L("Copied", "Kopiert") : L("Copy code", "Code kopieren")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                    }
                    .disabled(inactive)
                    .help(L("For the iPhone app's \"Paste code\" (Universal Clipboard). The clipboard is cleared when this closes.",
                            "Für „Code einfügen“ in der iPhone-App (Universelle Zwischenablage). Die Zwischenablage wird beim Schließen geleert."))
                }
                Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        // The keys must not stay on the clipboard.
        .onDisappear { Self.clearClipboard(code) }
        // Not in screenshots, screen recordings or screen sharing: the code holds the keys.
        .background(NoScreenCapture())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in inactive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inactive = false }
        .task {
            var keys = await PhoneLinkModel.collect()
            if keys.isEmpty { empty = true; return }
            keys.savingPerMonth = PhoneLinkModel.shared.savingPerMonth
            // One id per code: a phone can refuse one it used before (a photo of the screen).
            keys.once = UUID().uuidString
            code = PhoneLink.qrText(keys) ?? ""
            image = PhoneQRSheet.make(code)
            // Cancelled (the sheet closed): stop, instead of 60 turns without a pause.
            while left > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                left -= 1
            }
            dismiss()
        }
    }

    /// Sets the sheet's window so the system leaves it out of captures and sharing.
    private struct NoScreenCapture: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            DispatchQueue.main.async { v.window?.sharingType = .none }
            return v
        }
        func updateNSView(_ v: NSView, context: Context) { v.window?.sharingType = .none }
    }

    /// Empties the clipboard if it still holds this code (and only then).
    static func clearClipboard(_ code: String) {
        guard !code.isEmpty, NSPasteboard.general.string(forType: .string) == code else { return }
        NSPasteboard.general.clearContents()
    }

    static func make(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
    }
}
