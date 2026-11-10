// Deploy Center — Settings > Autofix: set up and watch `deploys autofix` without a terminal.
// A failed build is handed to a Claude Code routine that opens a fix PR; after the merge the
// fix is announced; deploying it stays a click. All the work is in the script; this view only calls it.

import SwiftUI
import AppKit

struct AutofixStatus: Decodable {
    struct Fire: Decodable, Identifiable {
        let at: Double
        let project: String
        let platform: String?
        let status: String
        let sha: String?
        let session: String?
        let error: String?
        let redeployedSha: String?
        let mergedSha: String?
        let pr: Int?
        var id: String { "\(project)-\(at)" }
    }
    let routine: String?
    let token: Bool
    let scheduled: Bool
    let fires: [Fire]
    /// A broken fire is skipped, not the reason Settings shows nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        routine = (try? c.decodeIfPresent(String.self, forKey: .routine)) ?? nil
        token = ((try? c.decodeIfPresent(Bool.self, forKey: .token)) ?? nil) ?? false
        scheduled = ((try? c.decodeIfPresent(Bool.self, forKey: .scheduled)) ?? nil) ?? false
        fires = (((try? c.decodeIfPresent([Lossy<Fire>].self, forKey: .fires)) ?? nil) ?? []).compactMap(\.value)
    }
    private enum K: String, CodingKey { case routine, token, scheduled, fires }
}

struct AutofixSettings: View {
    @State private var status: AutofixStatus?
    @State private var routineId = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var ready: Bool { status?.routine != nil && status?.token == true }

    var body: some View {
        Section {
            Text(L("When a build fails, a Claude Code session in the cloud fixes it and opens a pull request. Nothing is merged or deployed by itself: after you merge, deploy the fix here as usual.",
                   "Schlägt ein Build fehl, behebt eine Claude-Code-Sitzung in der Cloud den Fehler und öffnet einen Pull Request. Es wird nichts von selbst gemergt oder deployt: Nach deinem Merge deployst du den Fix hier wie gewohnt."))
                .font(.caption).foregroundStyle(.secondary)

            // 1. The routine: created on claude.ai, with the prompt copied from here.
            LabeledContent(L("1. Routine", "1. Routine")) {
                HStack {
                    Button(L("Copy prompt", "Prompt kopieren")) { Task { await copyPrompt() } }
                    Button(L("Open Claude routines", "Claude-Routinen öffnen")) {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/code/routines")!)
                    }
                }
            }
            .help(L("New routine: attach your repos, paste the prompt. Then Trigger > + > API > Generate token.",
                    "Neue Routine: Repos anhängen, Prompt einfügen. Dann Trigger > + > API > Generate token."))

            // 2. Its id and API token. The token goes to the keychain through the script's stdin.
            HStack {
                TextField(L("Routine ID", "Routinen-ID"), text: $routineId, prompt: Text("trig_…"))
                Button(L("Save", "Speichern")) { Task { await saveRoutine() } }
                    .disabled(!routineId.hasPrefix("trig_") || busy)
                check(status?.routine != nil)
            }
            HStack {
                SecureField(L("API token", "API-Token"), text: $token, prompt: Text("sk-ant-…"))
                Button(L("Save", "Speichern")) { Task { await saveToken() } }
                    .disabled(!token.hasPrefix("sk-ant-") || busy)
                check(status?.token == true)
            }

            // 3. Every 10 minutes through launchd, also while the app is closed.
            Toggle(L("3. Check every 10 minutes", "3. Alle 10 Minuten prüfen"), isOn: Binding(
                get: { status?.scheduled ?? false },
                set: { on in Task { await run(["autofix", "schedule", on ? "on" : "off"]) } }))
                .disabled(!ready || busy)

            HStack {
                Button(L("Test (sends nothing)", "Testen (sendet nichts)")) { Task { await run(["autofix", "--dry-run"], show: true) } }
                    .disabled(busy)
                Button(L("Run now", "Jetzt ausführen")) { Task { await run(["autofix"], show: true) } }
                    .disabled(!ready || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                    .foregroundStyle(failed ? .red : .secondary)
            }

            if let fires = status?.fires, !fires.isEmpty {
                DisclosureGroup(L("Last hand-overs (\(fires.count))", "Letzte Übergaben (\(fires.count))")) {
                    ForEach(fires) { f in
                        HStack {
                            Text(Date(timeIntervalSince1970: f.at).formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                            Text(Demo.mask(f.project))
                            Spacer()
                            Text(label(f)).foregroundStyle(f.status == "failed" ? .red : .secondary)
                            if let s = f.session, let url = URL(string: s) {
                                Button(L("Session", "Sitzung")) { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        } header: {
            Text("Autofix")
        }
        .task { await reload() }
    }

    private func check(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
    }

    private func label(_ f: AutofixStatus.Fire) -> String {
        if let r = f.mergedSha { return L("fix merged, ready to deploy", "Fix gemergt, bereit zum Deployen") + " (\(r.prefix(7)))" }
        if let r = f.redeployedSha { return L("fix deployed", "Fix deployt") + " (\(r.prefix(7)))" }
        switch f.status {
        case "fired": return L("session started", "Sitzung gestartet")
        case "ratelimited": return L("waiting (rate limit)", "wartet (Rate-Limit)")
        case "skipped": return L("fix failed too", "Fix ebenfalls fehlgeschlagen")
        case "failed": return L("could not start", "Start fehlgeschlagen")
        default: return f.status
        }
    }

    private func reload() async {
        status = try? await Tool.json(["autofix", "status"], as: AutofixStatus.self, timeout: 20)
        if routineId.isEmpty, let r = status?.routine { routineId = r }
    }

    private func copyPrompt() async {
        guard let data = try? await Tool.run(["autofix", "prompt"], timeout: 10), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        message = L("Prompt copied. Paste it into the new routine.", "Prompt kopiert. Füge ihn in die neue Routine ein."); failed = false
    }

    private func saveRoutine() async { await run(["autofix", "routine", routineId.trimmingCharacters(in: .whitespaces)]) }

    private func saveToken() async {
        busy = true; defer { busy = false }
        do {
            _ = try await Tool.run(["autofix", "set-token"], stdin: token.trimmingCharacters(in: .whitespacesAndNewlines), timeout: 20)
            token = ""; message = L("Token saved in the keychain.", "Token im Schlüsselbund gespeichert."); failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
    }

    /// A script call; with `show` its output is shown under the buttons.
    private func run(_ args: [String], show: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: 300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = show ? (out.isEmpty ? L("Nothing to do: no failed build.", "Nichts zu tun: kein fehlgeschlagener Build.") : out) : (out.isEmpty ? nil : out)
            failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
    }
}
