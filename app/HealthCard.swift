// Deploy Center — what `deploys doctor` says, per platform in one place (FEA-078), as a plain
// checklist with what to do (FEA-107, "why do I see nothing?"). Key expiry and the platforms'
// own rate limits are not in the doctor's answer yet; GitHub's budget is (Store.githubBudget).

import SwiftUI

struct HealthCheck: Identifiable, Equatable {
    let id: String
    let group: String
    let ok: Bool
    let text: String
    /// What to do about it; nil when it is fine.
    let fix: String?
}

enum Health {
    /// The checklist, from what is known. `on` are the platforms switched on (`providers`).
    nonisolated static func checks(_ d: Doctor?, budget: Store.Budget?, on: Set<String>, now: Date = Date()) -> [HealthCheck] {
        guard let d else {
            return [HealthCheck(id: "script", group: "deploys", ok: false,
                                text: L("The deploys script did not answer.", "Das deploys-Skript hat nicht geantwortet."),
                                fix: L("The error log (Help → Open the error log) says why; then check again.",
                                       "Das Fehlerprotokoll (Hilfe → Fehlerprotokoll öffnen) sagt, warum; dann erneut prüfen."))]
        }
        var out: [HealthCheck] = []
        func add(_ id: String, _ group: String, _ ok: Bool, _ good: String, _ bad: String, _ fix: String) {
            out.append(HealthCheck(id: id, group: group, ok: ok, text: ok ? good : bad, fix: ok ? nil : fix))
        }
        let tools = L("Tools", "Werkzeuge")
        add("jq", tools, d.jq, L("jq is installed.", "jq ist installiert."),
            L("jq is missing: no list can be read.", "jq fehlt: keine Liste ist lesbar."), "brew install jq")
        if let perl = d.perl {
            add("perl", tools, perl, L("perl is installed.", "perl ist installiert."),
                L("perl is missing: no log goes to Claude.", "perl fehlt: kein Log geht an Claude."), "brew install perl")
        }
        if let curl = d.curl {
            add("curl", tools, curl, L("curl is installed.", "curl ist installiert."),
                L("curl is missing: no platform can be asked.", "curl fehlt: keine Plattform ist erreichbar."), "brew install curl")
        }
        add("gh", "GitHub", d.githubCli, L("The GitHub CLI is installed.", "Die GitHub-CLI ist installiert."),
            L("The GitHub CLI is missing: waiting commits are not counted.", "Die GitHub-CLI fehlt: wartende Commits werden nicht gezählt."), "brew install gh")
        if d.githubCli, let logged = d.githubLoggedIn {
            add("ghlogin", "GitHub", logged, L("Logged in to GitHub.", "Bei GitHub angemeldet."),
                L("Not logged in to GitHub.", "Nicht bei GitHub angemeldet."), "gh auth login")
        }
        if let b = budget, b.limit > 0 {
            let low = Double(b.remaining) < Double(b.limit) * 0.1
            let reset = Date(timeIntervalSince1970: b.reset)
            let mins = max(0, Int(reset.timeIntervalSince(now) / 60))
            add("ghbudget", "GitHub", !low,
                L("GitHub requests left this hour: \(b.remaining) of \(b.limit).", "GitHub-Anfragen übrig diese Stunde: \(b.remaining) von \(b.limit)."),
                L("GitHub requests nearly spent: \(b.remaining) of \(b.limit), new ones in \(mins) min.",
                  "GitHub-Anfragen fast verbraucht: \(b.remaining) von \(b.limit), neue in \(mins) min."),
                L("The app asks less often until then.", "Die App fragt bis dahin seltener."))
        }
        if on.contains("vercel") {
            add("vercelcli", "Vercel", d.vercelCli, L("The Vercel CLI is installed.", "Die Vercel-CLI ist installiert."),
                L("The Vercel CLI is missing.", "Die Vercel-CLI fehlt."), "npm i -g vercel")
            add("vercellogin", "Vercel", d.vercelLoggedIn, L("Logged in to Vercel.", "Bei Vercel angemeldet."),
                L("Not logged in to Vercel: no projects show.", "Nicht bei Vercel angemeldet: keine Projekte erscheinen."), "vercel login")
            if d.vercelCli && d.vercelLoggedIn {
                add("vercelapi", "Vercel", d.vercelApi, L("Vercel's API answers.", "Die Vercel-API antwortet."),
                    L("Vercel's API does not answer with this login.", "Die Vercel-API antwortet mit dieser Anmeldung nicht."),
                    L("Log in again: vercel login", "Neu anmelden: vercel login"))
            }
        }
        if on.contains("render") {
            add("renderkey", "Render", d.renderKey, L("A Render API key is stored.", "Ein Render-API-Schlüssel ist gespeichert."),
                L("No Render API key: no services show.", "Kein Render-API-Schlüssel: keine Dienste erscheinen."), "deploys render set-key")
        }
        add("jobs", L("Scheduled jobs", "Geplante Aufgaben"), d.jobsMissing.isEmpty,
            L("Scheduled jobs find their tools.", "Geplante Aufgaben finden ihre Werkzeuge."),
            L("Scheduled jobs miss tools: \(d.jobsMissing.joined(separator: ", ")).", "Geplanten Aufgaben fehlen Werkzeuge: \(d.jobsMissing.joined(separator: ", "))."),
            L("Set them up again in Settings → Deploy.", "Unter Einstellungen → Deploy neu einrichten."))
        if d.readonly {
            out.append(HealthCheck(id: "readonly", group: "deploys", ok: false,
                                   text: L("Observer mode: the script refuses every deploy.", "Beobachtermodus: Das Skript lehnt jeden Deploy ab."),
                                   fix: L("Remove ~/.config/deploys/readonly or unset DEPLOYS_READONLY.", "~/.config/deploys/readonly löschen oder DEPLOYS_READONLY entfernen.")))
        }
        return out
    }

    /// Plain text of the problems, for "Copy": no names, no keys.
    nonisolated static func summary(_ checks: [HealthCheck]) -> String {
        let bad = checks.filter { !$0.ok }
        guard !bad.isEmpty else { return L("All checks passed.", "Alle Prüfungen bestanden.") }
        return bad.map { "– " + $0.text + ($0.fix.map { " → " + $0 } ?? "") }.joined(separator: "\n")
    }
}

/// The card in Settings → Platforms.
struct HealthCard: View {
    @ObservedObject var store: Store
    @State private var checking = false

    var body: some View {
        let checks = Health.checks(store.doctor, budget: store.githubBudget, on: Set(store.enabledProviders.map(\.id)))
        Section(L("Health", "Zustand")) {
            ForEach(checks) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.ok ? Color.good : Color.orange)
                        .accessibilityLabel(c.ok ? L("fine", "in Ordnung") : L("problem", "Problem"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.text)
                        if let f = c.fix { Text(f).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer()
                    Text(c.group).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(checking ? L("Checking …", "Prüfe …") : L("Check again", "Erneut prüfen")) {
                    checking = true
                    Task {
                        if let d = try? await Tool.json(["doctor"], as: Doctor.self, timeout: 60) { store.doctor = d; store.doctorError = nil }
                        checking = false
                    }
                }.disabled(checking)
                CopyButton(title: L("Copy problems", "Probleme kopieren")) { Health.summary(checks) }
            }
            Text(L("Key expiry and the platforms' own request limits are not reported by the script yet.",
                   "Ablauf der Schlüssel und die Anfragegrenzen der Plattformen meldet das Skript noch nicht."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
