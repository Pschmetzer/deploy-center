// Deploy Center — The setup screens in the main window (a missing login or the Render key).

import SwiftUI
import AppKit

struct Setup: View {
    let title: String
    let text: String
    let commands: [String]
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(commands, id: \.self) { c in
                HStack {
                    Text(c).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    CopyButton(title: L("Copy \(c)", "\(c) kopieren"), systemImage: "doc.on.doc") { c }.buttonStyle(.borderless)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
            Button(L("Done – check again", "Fertig – nochmal prüfen"), action: retry).buttonStyle(.borderedProminent)
        }
        .padding(30).frame(maxWidth: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RenderKeySetup: View {
    @ObservedObject var store: Store
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("Connect Render", "Render verbinden")).font(.title2.weight(.semibold))
            Text(L("Create an API key at dashboard.render.com → Account Settings → API Keys and paste it here. It is stored in your macOS keychain, nowhere else.",
                   "Erstelle einen API-Key unter dashboard.render.com → Account Settings → API Keys und füge ihn hier ein. Er wird nur im macOS-Schlüsselbund gespeichert."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField(L("Render API key", "Render-API-Key"), text: $key, prompt: Text("rnd_…"))
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { if canSave { save() } }
            if !key.isEmpty && !looksRight {
                Text(L("A Render API key starts with rnd_.", "Ein Render-API-Key beginnt mit rnd_."))
                    .font(.caption).foregroundStyle(Color.warningText)
            }
            if let error { ErrorText(error).multilineTextAlignment(.center) }
            HStack {
                Button(L("Open Render", "Render öffnen")) {
                    NSWorkspace.shared.open(URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
                }
                Button(saving ? L("Saving …", "Speichere …") : L("Save key", "Key speichern")) { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .padding(30).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var looksRight: Bool { trimmed.hasPrefix("rnd_") && trimmed.count >= 10 }
    private var canSave: Bool { looksRight && !saving }
    private func save() {
        saving = true
        Task { error = await store.saveRenderKey(key); saving = false; if error == nil { key = "" } }
    }
}
