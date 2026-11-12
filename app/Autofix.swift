// Deploy Center — Settings > Autofix: set up and watch `deploys autofix` without a terminal.
// A failed build is handed to a Claude Code routine that opens a fix PR; after the merge the
// fix is announced; deploying it stays a click. All the work is in the script; this view only calls it.

import SwiftUI
import AppKit

struct AutofixStatus: Decodable {
    /// The same fire as the rows read (Model.swift), with its PR state.
    typealias Fire = AutofixReport.Fire
    let routine: String?
    let token: Bool
    let scheduled: Bool
    let fires: [Fire]
    /// Tools the scheduled job no longer finds on its PATH (newer scripts).
    let pathMissing: [String]
    /// A broken fire is skipped, not the reason Settings shows nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        routine = (try? c.decodeIfPresent(String.self, forKey: .routine)) ?? nil
        token = ((try? c.decodeIfPresent(Bool.self, forKey: .token)) ?? nil) ?? false
        scheduled = ((try? c.decodeIfPresent(Bool.self, forKey: .scheduled)) ?? nil) ?? false
        fires = (((try? c.decodeIfPresent([Lossy<Fire>].self, forKey: .fires)) ?? nil) ?? []).compactMap(\.value)
        pathMissing = ((try? c.decodeIfPresent([String].self, forKey: .pathMissing)) ?? nil) ?? []
    }
    private enum K: String, CodingKey { case routine, token, scheduled, fires, pathMissing }
}

struct AutofixSettings: View {
    /// The rows read the same status: after a run here they are brought up to date at once.
    @ObservedObject var store: Store
    /// The projects, so demo mode can replace their names in the script's output.
    private var items: [Item] { store.items.values.flatMap { $0 } }
    /// Read so the output redraws at once when demo mode is switched (⇧⌘D).
    @AppStorage("demoMode") private var demoMode = false
    @State private var status: AutofixStatus?
    /// A failed read keeps the last good status on screen, with this under it.
    @State private var readError: String?
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
            // The steps on claude.ai, on screen and not only in a tooltip.
            VStack(alignment: .leading, spacing: 2) {
                Text(L("a. New routine: attach your repos, paste the prompt.", "a. Neue Routine: Repos anhängen, Prompt einfügen."))
                Text(L("b. Trigger › + › API › Generate token.", "b. Trigger › + › API › Generate token."))
                Text(L("c. Copy the routine ID and the token into the fields below.", "c. Routinen-ID und Token unten eintragen."))
            }
            .font(.caption).foregroundStyle(.secondary)

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
            if let s = status, s.scheduled, !s.pathMissing.isEmpty {
                PathMissingLine(missing: s.pathMissing, busy: busy) { Task { await run(["autofix", "schedule", "on"]) } }
            }

            HStack {
                Button(L("Test (sends nothing)", "Testen (sendet nichts)")) { Task { await run(["autofix", "--dry-run"], show: true) } }
                    .disabled(busy)
                // One hand-over at a time: a row's "Fix with Claude" holds the script's lock too.
                Button(L("Run now", "Jetzt ausführen")) { Task { await run(["autofix"], show: true) } }
                    .disabled(!ready || busy || !store.autofixRunning.isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            if let readError {
                ErrorText(L("Could not read the autofix status: ", "Autofix-Status nicht lesbar: ") + Demo.scrub(readError, items: items))
            }
            if let message {
                if failed { ErrorText(Demo.scrub(message, items: items)) }
                else { Text(Demo.scrub(message, items: items)).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            }

            if let fires = status?.fires, !fires.isEmpty {
                DisclosureGroup(L("Last hand-overs (\(fires.count))", "Letzte Übergaben (\(fires.count))")) {
                    ForEach(fires) { f in
                        HStack {
                            Text(Date(timeIntervalSince1970: f.at).formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                            Text(Demo.mask(f.project))
                            Spacer()
                            if f.status == "failed" { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true) }
                            Text(Self.label(f)).foregroundStyle(f.status == "failed" ? .red : .secondary)
                            if let n = f.prNumber, let s = f.prUrl, let url = URL(string: s), !Demo.on {
                                Button("PR #\(n)") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                            }
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
        Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.good : .secondary)
    }

    static func label(_ f: AutofixStatus.Fire) -> String {
        if let r = f.redeployedSha { return L("fix deployed", "Fix deployt") + " (\(r.prefix(7)))" }
        if let r = f.mergedSha { return L("fix merged, ready to deploy", "Fix gemergt, bereit zum Deployen") + " (\(r.prefix(7)))" }
        // The PR's state says more than "session started".
        switch f.prState {
        case "open": return f.done ? L("green again, fix PR still open", "wieder grün, Fix-PR noch offen") : L("fix PR open", "Fix-PR offen")
        case "closed": return L("fix PR closed unmerged", "Fix-PR ungemergt geschlossen")
        default: break
        }
        if f.done { return L("green again", "wieder grün") }
        switch f.status {
        case "fired": return L("session started", "Sitzung gestartet")
        case "pending": return L("starting", "startet")
        case "unsupported": return L("not supported (GitHub only)", "nicht unterstützt (nur GitHub)")
        case "ratelimited": return L("waiting (rate limit)", "wartet (Rate-Limit)")
        case "skipped": return L("fix failed too", "Fix ebenfalls fehlgeschlagen")
        case "failed": return L("could not start", "Start fehlgeschlagen")
        default: return unknownCode(f.status, L("status", "Status"))
        }
    }

    private func reload() async {
        do {
            status = try await Tool.json(["autofix", "status"], as: AutofixStatus.self, timeout: 20)
            readError = nil
        } catch { readError = error.localizedDescription }
        if routineId.isEmpty, let r = status?.routine { routineId = r }
    }

    private func copyPrompt() async {
        let text: String
        do {
            guard let t = String(data: try await Tool.run(["autofix", "prompt"], timeout: 10), encoding: .utf8), !t.isEmpty else {
                message = L("The prompt came back empty.", "Der Prompt kam leer zurück."); failed = true; return
            }
            text = t
        } catch {
            message = L("Could not copy the prompt: ", "Prompt ließ sich nicht kopieren: ") + error.localizedDescription; failed = true; return
        }
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
        // A real hand-over takes the script's lock: the rows wait for it (Store.autofixBusy).
        let handsOver = args == ["autofix"]
        if handsOver { store.autofixRunning.insert(Store.autofixAllKey) }
        defer { if handsOver { store.autofixRunning.remove(Store.autofixAllKey) } }
        do {
            let out = String(data: try await Tool.run(args, timeout: 300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = show ? (out.isEmpty ? L("Nothing to do: no failed build.", "Nichts zu tun: kein fehlgeschlagener Build.") : out) : (out.isEmpty ? nil : out)
            failed = false
        } catch { message = error.localizedDescription; failed = true }
        await reload()
        // The rows show the new hand-over now, not at the next refresh (a dry run changes nothing).
        if !args.contains("--dry-run") { await store.loadAgentStatus() }
    }
}
