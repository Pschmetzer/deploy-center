// Deploy Center — The Claude desktop app's Code sessions, for every account signed in on this Mac: how many are done
// (every pull request merged or closed, nothing running, nobody asked) but still open. The figures come from
// `deploys desktop-sessions --json` (lib/desktopsessions.sh). Read-only: archiving is the Claude app's own job, through
// its setting "Auto-archive sessions when their pull request closes" (Settings → Claude Code), once per account. Its
// session files are private app state and are never written from here. Notifications only for what is new.
// Stopped sessions (usage limit, API error, a turn cut off) are listed with an "Open in Claude" button; nothing resumes
// them from here, because no supported way to continue a desktop session exists outside the app.

import AppKit
import SwiftUI

struct DesktopSessionsSnapshot: Decodable, Equatable {
    struct Totals: Decodable, Equatable { let accounts: Int; let open: Int; let done: Int; let waiting: Int; let running: Int; let stopped: Int; let accountsWithDone: Int }
    struct PR: Decodable, Equatable { let state: String; let number: Int? }
    struct Session: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let folder: String
        let state: String
        let idleHours: Int?
        let prs: [PR]
        /// stopped: limit, error or cut (a turn that ended without an answer); stopKey is the last transcript entry.
        let stopReason: String?
        let stopKey: String?
        let stopNote: String?
        let openUrl: String
    }
    struct Account: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let active: Bool
        let open: Int
        let done: Int
        let waiting: Int
        let running: Int
        let stopped: Int
        let sessions: [Session]
    }
    let totals: Totals
    let accounts: [Account]
}

enum DesktopSessionsText {
    /// "Done, still open: 14 across 5 accounts"
    static func summary(_ s: DesktopSessionsSnapshot) -> String {
        let n = s.totals.accounts, st = s.totals.stopped
        return L("Done, still open: \(s.totals.done) across \(n) \(n == 1 ? "account" : "accounts")",
                 "Fertig, noch offen: \(s.totals.done) in \(n) \(n == 1 ? "Konto" : "Konten")")
            + (st > 0 ? L(" · \(st) stopped", " · \(st) stehen geblieben") : "")
    }

    static func account(_ a: DesktopSessionsSnapshot.Account) -> String {
        let me = a.active ? L(" (signed in)", " (angemeldet)") : ""
        return L("\(a.label)\(me): \(a.done) done, \(a.waiting) waiting on you, \(a.stopped) stopped, \(a.open) open",
                 "\(a.label)\(me): \(a.done) fertig, \(a.waiting) warten auf dich, \(a.stopped) stehen geblieben, \(a.open) offen")
    }

    static func name(_ s: DesktopSessionsSnapshot.Session) -> String {
        Demo.mask(s.title.isEmpty ? s.folder : s.title)
    }

    static func prs(_ s: DesktopSessionsSnapshot.Session) -> String {
        s.prs.map { "#\($0.number.map(String.init) ?? "?")" }.joined(separator: ", ")
    }

    /// "limit (resets Dec 1 at 11am)", "API error", "cut off"
    static func reason(_ s: DesktopSessionsSnapshot.Session) -> String {
        switch s.stopReason {
        case "limit"?: return L("usage limit", "Nutzungslimit") + (s.stopNote.map { " (\($0))" } ?? "")
        case "error"?: return L("API error", "API-Fehler")
        default: return L("cut off mid-turn", "mitten im Schritt abgebrochen")
        }
    }

    static func open(_ s: DesktopSessionsSnapshot.Session) {
        if let u = URL(string: s.openUrl), u.scheme == "claude" { NSWorkspace.shared.open(u) }
    }

    static let hint = L("Archiving is done by the Claude app: turn on “Auto-archive sessions when their pull request closes” (Settings → Claude Code) in this account.",
                        "Das Archivieren macht die Claude-App: in diesem Konto „Auto-archive sessions when their pull request closes“ einschalten (Einstellungen → Claude Code).")
}

@MainActor
final class DesktopSessionsMonitor: ObservableObject {
    static let shared = DesktopSessionsMonitor()
    @Published private(set) var snapshot: DesktopSessionsSnapshot?
    private var task: Task<Void, Never>?
    private let seenKey = "desktopSessionsSeen"
    /// Notifications for stopped sessions are opt-in (the switch in the menu); at most `perHour` and `perDay` of them.
    static let stoppedKey = "desktopSessionsStoppedNotify"
    private let sentKey = "desktopSessionsStoppedSent"
    private let perHour = 6, perDay = 30

    /// Every five minutes while the Claude Code line is switched on (the same switch as app/LocalSessions.swift).
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    func refresh() async {
        guard UserDefaults.standard.object(forKey: LocalSessionsMonitor.key) as? Bool ?? true else { return }
        do {
            let s = try await Tool.json(["desktop-sessions", "--json"], as: DesktopSessionsSnapshot.self, timeout: 60)
            if s != snapshot { snapshot = s }
            tell(s)
        } catch {
            if snapshot != nil { snapshot = nil }
        }
    }

    /// One notification per session that newly became done or newly waits on you. The first look is the silent
    /// baseline, so a fresh install does not announce everything that is already there.
    private func tell(_ s: DesktopSessionsSnapshot) {
        let d = UserDefaults.standard
        let first = d.object(forKey: seenKey) == nil
        var seen = Set(d.stringArray(forKey: seenKey) ?? [])
        var live = Set<String>()
        for a in s.accounts {
            for x in a.sessions where x.state == "done" || x.state == "waiting" || x.state == "stopped" {
                // A stopped session is told once per stop point: a new stop after it ran again is news again.
                let key = x.state == "stopped" ? "stopped:\(x.id):\(x.stopKey ?? "")" : "\(x.state):\(x.id)"
                live.insert(key)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                guard !first, d.object(forKey: "sessionNotifications") as? Bool ?? true else { continue }
                if x.state == "stopped" {
                    guard d.bool(forKey: Self.stoppedKey), allowStopped(d) else { continue }
                    Notify.remind(L("A session stopped", "Eine Sitzung ist stehen geblieben"),
                                  L("\(DesktopSessionsText.name(x)) (\(a.label)): \(DesktopSessionsText.reason(x)). Open it in Claude to continue.",
                                    "\(DesktopSessionsText.name(x)) (\(a.label)): \(DesktopSessionsText.reason(x)). In Claude öffnen, um weiterzumachen."),
                                  id: "desktop-session-" + key)
                } else if x.state == "done" {
                    Notify.remind(L("Session done, still open", "Sitzung fertig, noch offen"),
                                  L("\(DesktopSessionsText.name(x)) (\(a.label)): \(DesktopSessionsText.prs(x)) merged or closed. The Claude app can archive it.",
                                    "\(DesktopSessionsText.name(x)) (\(a.label)): \(DesktopSessionsText.prs(x)) gemergt oder geschlossen. Die Claude-App kann sie archivieren."),
                                  id: "desktop-session-" + key)
                } else {
                    Notify.remind(L("A session waits on you", "Eine Sitzung wartet auf dich"),
                                  "\(DesktopSessionsText.name(x)) (\(a.label))", id: "desktop-session-" + key)
                }
            }
        }
        // Only keys still shown are kept, so the memory does not grow without end.
        d.set(Array(seen.intersection(live)), forKey: seenKey)
    }

    /// The caps for stopped notices: the times of the last ones sent, kept for a day.
    private func allowStopped(_ d: UserDefaults) -> Bool {
        let now = Date().timeIntervalSince1970
        var sent = (d.array(forKey: sentKey) as? [Double] ?? []).filter { now - $0 < 86_400 }
        guard sent.count < perDay, sent.filter({ now - $0 < 3_600 }).count < perHour else { return false }
        sent.append(now); d.set(sent, forKey: sentKey)
        return true
    }
}

/// The switch for keeping idle sessions going: ~/.config/deploys/nudge.json {"enabled": …}, on when missing.
/// Deploy Center only stores it; the user's own scheduled task that nudges idle sessions reads it.
enum NudgeSetting {
    static var url: URL {
        let base = ProcessInfo.processInfo.environment["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
        return base.appendingPathComponent("nudge.json")
    }
    static var enabled: Bool {
        get {
            guard let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
            return (o["enabled"] as? Bool) ?? true
        }
        set {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("{\"enabled\": \(newValue)}\n".utf8).write(to: url, options: .atomic)
        }
    }
}

/// The lines in the menu: one summary, and per account the done sessions with the archive hint.
struct DesktopSessionsMenuSection: View {
    @ObservedObject var mon = DesktopSessionsMonitor.shared
    @AppStorage(DesktopSessionsMonitor.stoppedKey) private var stoppedNotify = false
    @State private var nudge = NudgeSetting.enabled

    var body: some View {
        if let s = mon.snapshot, s.totals.accounts > 0 {
            Menu(DesktopSessionsText.summary(s)) {
                Text(L("Claude desktop sessions whose pull requests are all merged or closed, with nothing running.",
                       "Claude-Desktop-Sitzungen, deren Pull Requests alle gemergt oder geschlossen sind und in denen nichts läuft."))
                ForEach(s.accounts) { a in
                    Divider()
                    Text(DesktopSessionsText.account(a))
                    ForEach(a.sessions.filter { $0.state == "done" }.prefix(10)) { x in
                        Text("   " + DesktopSessionsText.name(x) + " – " + DesktopSessionsText.prs(x))
                    }
                    ForEach(a.sessions.filter { $0.state == "stopped" }.prefix(10)) { x in
                        Button(L("   Open in Claude: ", "   In Claude öffnen: ") + DesktopSessionsText.name(x) + " – " + DesktopSessionsText.reason(x)) {
                            DesktopSessionsText.open(x)
                        }
                    }
                    Text(DesktopSessionsText.hint).font(.caption)
                }
                Divider()
                Toggle(L("Keep idle sessions going automatically", "Untätige Sitzungen automatisch weiterlaufen lassen"), isOn: Binding(
                    get: { nudge },
                    set: { nudge = $0; NudgeSetting.enabled = $0 }))
                Toggle(L("Notify when a session stopped (limit, error, cut off)", "Melden, wenn eine Sitzung stehen bleibt (Limit, Fehler, Abbruch)"), isOn: $stoppedNotify)
                Text(L("Read-only: Deploy Center archives and resumes nothing.", "Nur lesend: Deploy Center archiviert nichts und setzt nichts fort."))
            }
        }
    }
}
