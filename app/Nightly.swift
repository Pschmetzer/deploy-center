// Deploy Center — Settings > Claude > Nightly check: `deploys nightly` without a terminal.
// Every night the security check (OSV-Scanner, gitleaks, Semgrep) runs on each repo; only findings
// not seen before count. With "Claude fixes" on, those go to a bug scan that opens a PR. Nothing is
// merged or deployed. All the work is in lib/nightly.sh; this view only calls it.

import SwiftUI

struct NightlyReport: Decodable {
    let scheduled: Bool
    let at: String
    let fix: Bool
    let skip: [String]
    let review: Bool?
    let reviewDay: Int?
    let maxScans: Int
    let pathMissing: [String]
    let lastRun: Double?
    let failing: [String]?
    let repos: [Repo]
    struct Repo: Decodable, Identifiable {
        let repo: String
        let at: Double?
        let newFindings: Int
        let newLeaks: Int
        let scanId: String?
        let scanStatus: String?
        let prUrl: String?
        /// baseline | checkFailed | limit | refused (then `note` is the script's reason) | nil
        let code: String?
        let note: String?
        let known: Int?
        let reviewedSha: String?
        let reviewPending: Bool?
        let reviewCode: String?
        let reviewNote: String?
        let reviewStatus: String?
        var id: String { repo }
    }
}

struct NightlySettings: View {
    @ObservedObject var store: Store
    @AppStorage("demoMode") private var demoMode = false
    @State private var status: NightlyReport?
    @State private var readError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var confirmRun = false

    private var hour: Binding<Int> {
        Binding(get: { Int(status?.at.prefix(2) ?? "3") ?? 3 },
                set: { h in Task { await run(["nightly", "schedule", "on", String(format: "%02d:00", h)]) } })
    }

    var body: some View {
        Section {
            Text(L("Every night, OSV-Scanner, gitleaks and Semgrep check each repo of your projects (free, on this Mac, no code of the repo runs). The first check of a repo is its starting point; after that only new findings count. Nothing is merged or deployed.",
                   "Jede Nacht prüfen OSV-Scanner, gitleaks und Semgrep jedes Repo deiner Projekte (kostenlos, auf diesem Mac, kein Code des Repos läuft). Die erste Prüfung eines Repos ist der Ausgangsstand; danach zählen nur neue Funde. Es wird nichts gemergt oder deployt."))
                .font(.caption).foregroundStyle(.secondary)

            Toggle(L("Check every night", "Jede Nacht prüfen"), isOn: Binding(
                get: { status?.scheduled ?? false },
                set: { on in Task {
                    if !on, !(await OwnerCheck.confirm(L("switch the nightly security check off", "die nächtliche Sicherheitsprüfung ausschalten"))) { return }
                    await run(["nightly", "schedule", on ? "on" : "off"]) } }))
                .disabled(busy || status == nil)
            if status?.scheduled == true {
                Picker(L("At", "Um"), selection: hour) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                .disabled(busy)
                Text(L("A Mac that sleeps at that time runs it when it wakes.", "Schläft der Mac um diese Zeit, läuft die Prüfung beim Aufwachen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = status, s.scheduled, !s.pathMissing.isEmpty {
                PathMissingLine(missing: s.pathMissing, busy: busy) { Task { await run(["nightly", "schedule", "on"]) } }
            }

            Toggle(L("Claude fixes new findings", "Claude behebt neue Funde"), isOn: Binding(
                get: { status?.fix ?? false },
                set: { on in Task { await run(["nightly", "fix", on ? "on" : "off"]) } }))
                .disabled(busy || status == nil)
            Text(L("New vulnerable packages and serious Semgrep findings go to a bug scan with Claude Code on this Mac, at most \(status?.maxScans ?? 2) a night. It opens a pull request; you review and merge. Leaked keys are only reported: rotate them.",
                   "Neue verwundbare Pakete und ernste Semgrep-Funde gehen an einen Bug-Scan mit Claude Code auf diesem Mac, höchstens \(status?.maxScans ?? 2) pro Nacht. Er öffnet einen Pull Request; du prüfst und mergst. Geleakte Schlüssel werden nur gemeldet: Tausche sie aus."))
                .font(.caption).foregroundStyle(.secondary)

            // The weekly review runs inside the nightly run: only offered while that is scheduled.
            if status?.scheduled == true {
                Toggle(L("Claude reviews the week's changes", "Claude prüft die Änderungen der Woche"), isOn: Binding(
                    get: { status?.review ?? false },
                    set: { on in Task { await run(["nightly", "review", on ? "on" : "off"]) } }))
                    .disabled(busy)
                if status?.review == true {
                    Picker(L("On", "Am"), selection: Binding(
                        get: { status?.reviewDay ?? 7 },
                        set: { d in Task { await run(["nightly", "review", "on", String(d)]) } })) {
                        ForEach(1...7, id: \.self) { d in Text(Self.weekday(d)).tag(d) }
                    }
                    .disabled(busy)
                }
                Text(L("Once a week Claude reads each repo's changes since the last review and looks for bugs they brought in, then opens a pull request. It shares the nightly limit of \(status?.maxScans ?? 2) scans with the fixes, so a week of reviews can take several nights.",
                       "Einmal pro Woche liest Claude die Änderungen jedes Repos seit der letzten Prüfung, sucht nach Bugs, die sie mitgebracht haben, und öffnet einen Pull Request. Das teilt sich die Grenze von \(status?.maxScans ?? 2) Scans pro Nacht mit den Fixes; eine Review-Woche kann sich daher über mehrere Nächte ziehen."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Run now", "Jetzt ausführen")) { confirmRun = true }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let readError {
                ErrorText(L("Could not read the nightly check: ", "Nächtliche Prüfung nicht lesbar: ") + Demo.scrub(readError, items: store.allItems))
            }
            if let message {
                if failed { ErrorText(Demo.scrub(message, items: store.allItems)) }
                else { Text(Demo.scrub(message, items: store.allItems)).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary) }
            }
            if let s = status, let t = s.lastRun {
                Text(L("Last run: ", "Letzter Lauf: ") + Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
                     + " · " + Self.summary(s, at: t))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let repos = status?.repos, !repos.isEmpty {
                DisclosureGroup(L("Repos (\(repos.count))", "Repos (\(repos.count))")) {
                    ForEach(repos) { r in
                        HStack {
                            Text(Demo.on ? Demo.mask(r.repo) : r.repo)
                            Spacer()
                            Text(Demo.scrub(Self.label(r), items: store.allItems)).foregroundStyle(r.newLeaks > 0 ? Color.warningText : .secondary)
                            if let s = r.prUrl, let url = URL(string: s), !Demo.on {
                                Button("PR") { SafeLink.open(url) }.buttonStyle(.link)
                            }
                            Button(status?.skip.contains(r.repo) == true ? L("Include", "Aufnehmen") : L("Skip", "Auslassen")) {
                                Task { await run(["nightly", status?.skip.contains(r.repo) == true ? "unskip" : "skip", r.repo]) }
                            }
                            .buttonStyle(.link).disabled(busy)
                        }
                        .font(.caption)
                    }
                }
            }
        } header: {
            Text(L("Nightly check", "Nächtliche Prüfung"))
        }
        .task { await reload() }
        .confirmationDialog(L("Check every repo now?", "Jetzt jedes Repo prüfen?"), isPresented: $confirmRun, titleVisibility: .visible) {
            Button(L("Run now", "Jetzt ausführen")) { Task { await run(["nightly", "start"]) } }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("It runs in the background and can take a while. The first check of a repo only notes what is there. With \"Claude fixes new findings\" on, it may start bug scans that open pull requests.",
                   "Es läuft im Hintergrund und kann eine Weile dauern. Die erste Prüfung eines Repos merkt sich nur, was da ist. Ist „Claude behebt neue Funde“ an, kann es Bug-Scans starten, die Pull Requests öffnen."))
        }
    }

    static func label(_ r: NightlyReport.Repo) -> String {
        var parts: [String] = []
        if r.newFindings > 0 { parts.append(L("\(r.newFindings) new", "\(r.newFindings) neu")) }
        if r.newLeaks > 0 { parts.append(L("\(r.newLeaks) leaked key(s)", "\(r.newLeaks) geleakte(r) Schlüssel")) }
        switch r.scanStatus {
        case "pr"?: parts.append(L("fix PR open", "Fix-PR offen"))
        case "clean"?: parts.append(L("Claude found nothing to fix", "Claude fand nichts zu beheben"))
        case "failed"?: parts.append(L("scan failed", "Scan fehlgeschlagen"))
        case "running"?: parts.append(L("scan running", "Scan läuft"))
        default: break
        }
        switch r.code {
        case "baseline"?: parts.append(L("first check: \(r.known ?? 0) known finding(s) taken as the starting point", "erste Prüfung: \(r.known ?? 0) bekannte(r) Fund(e) als Ausgangsstand"))
        case "checkFailed"?: parts.append(L("the check failed", "die Prüfung schlug fehl"))
        case "limit"?: parts.append(L("waits for the next night (scan limit)", "wartet auf die nächste Nacht (Scan-Grenze)"))
        case "refused"?: parts.append(L("scan not started: ", "Scan nicht gestartet: ") + (r.note ?? ""))
        default: break
        }
        switch r.reviewCode {
        case "reviewWaiting"?: parts.append(L("review waits (scan limit)", "Review wartet (Scan-Grenze)"))
        case "reviewFailed"?: parts.append(L("review failed, tried again", "Review fehlgeschlagen, neuer Versuch"))
        case "reviewGaveUp"?: parts.append(L("review failed twice, next week again", "Review zweimal fehlgeschlagen, nächste Woche wieder"))
        case "refused"?: parts.append(L("review not started: ", "Review nicht gestartet: ") + (r.reviewNote ?? ""))
        default:
            if r.reviewStatus == "pr" { parts.append(L("review PR open", "Review-PR offen")) }
            else if let sha = r.reviewedSha { parts.append(L("reviewed up to \(sha.prefix(7))", "geprüft bis \(sha.prefix(7))")) }
        }
        return parts.isEmpty ? L("nothing new", "nichts Neues") : parts.joined(separator: " · ")
    }

    /// 1 Monday … 7 Sunday, in the person's language.
    static func weekday(_ d: Int) -> String {
        let names = [L("Monday", "Montag"), L("Tuesday", "Dienstag"), L("Wednesday", "Mittwoch"), L("Thursday", "Donnerstag"),
                     L("Friday", "Freitag"), L("Saturday", "Samstag"), L("Sunday", "Sonntag")]
        return names[max(1, min(7, d)) - 1]
    }

    /// The last run in one line, from the counts (the script's own summary is English only).
    static func summary(_ s: NightlyReport, at t: Double) -> String {
        let last = s.repos.filter { $0.at == t }
        let new = last.reduce(0) { $0 + $1.newFindings }, leaks = last.reduce(0) { $0 + $1.newLeaks }
        let prs = last.filter { $0.scanStatus == "pr" }.count, failed = s.failing?.count ?? 0
        var line = L("\(last.count) repos, \(new) new finding(s), \(leaks) new leaked key(s), \(prs) fix PR(s)",
                     "\(last.count) Repos, \(new) neue(r) Fund(e), \(leaks) neue(r) geleakte(r) Schlüssel, \(prs) Fix-PR(s)")
        if failed > 0 { line += L(", \(failed) check(s) failed", ", \(failed) Prüfung(en) fehlgeschlagen") }
        return line
    }

    private func reload() async {
        do {
            status = try await Tool.json(["nightly", "status"], as: NightlyReport.self, timeout: 20)
            readError = nil
        } catch { readError = error.localizedDescription }
    }

    private func run(_ args: [String], timeout: Double = 60) async {
        busy = true; defer { busy = false }
        do {
            let out = String(data: try await Tool.run(args, timeout: timeout), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let safe = LogTools.maskSecrets(out)
            message = safe.isEmpty ? nil : safe; failed = false
        } catch { message = LogTools.maskSecrets(error.localizedDescription); failed = true }
        await reload()
    }
}
