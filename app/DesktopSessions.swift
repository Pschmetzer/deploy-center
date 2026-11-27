// Deploy Center — The Claude desktop app's Code sessions, for every account signed in on this Mac: how many are done
// (every pull request merged or closed, nothing running, nobody asked) but still open. The figures come from
// `deploys desktop-sessions --json` (lib/desktopsessions.sh). Read-only: archiving is the Claude app's own job, through
// its setting "Auto-archive sessions when their pull request closes" (Settings → Claude Code), once per account. Its
// session files are private app state and are never written from here. Notifications only for what is new.

import AppKit
import SwiftUI

struct DesktopSessionsSnapshot: Decodable, Equatable {
    struct Totals: Decodable, Equatable { let accounts: Int; let open: Int; let done: Int; let waiting: Int; let running: Int; let accountsWithDone: Int }
    struct PR: Decodable, Equatable { let state: String; let number: Int? }
    struct Session: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let folder: String
        let state: String
        let idleHours: Int?
        let prs: [PR]
    }
    struct Account: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let active: Bool
        let open: Int
        let done: Int
        let waiting: Int
        let running: Int
        let sessions: [Session]
    }
    let totals: Totals
    let accounts: [Account]
}

enum DesktopSessionsText {
    /// "Done, still open: 14 across 5 accounts"
    static func summary(_ s: DesktopSessionsSnapshot) -> String {
        let n = s.totals.accounts
        return L("Done, still open: \(s.totals.done) across \(n) \(n == 1 ? "account" : "accounts")",
                 "Fertig, noch offen: \(s.totals.done) in \(n) \(n == 1 ? "Konto" : "Konten")")
    }

    static func account(_ a: DesktopSessionsSnapshot.Account) -> String {
        let me = a.active ? L(" (signed in)", " (angemeldet)") : ""
        return L("\(a.label)\(me): \(a.done) done, \(a.waiting) waiting on you, \(a.open) open",
                 "\(a.label)\(me): \(a.done) fertig, \(a.waiting) warten auf dich, \(a.open) offen")
    }

    static func name(_ s: DesktopSessionsSnapshot.Session) -> String {
        Demo.mask(s.title.isEmpty ? s.folder : s.title)
    }

    static func prs(_ s: DesktopSessionsSnapshot.Session) -> String {
        s.prs.map { "#\($0.number.map(String.init) ?? "?")" }.joined(separator: ", ")
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
            for x in a.sessions where x.state == "done" || x.state == "waiting" {
                let key = "\(x.state):\(x.id)"
                live.insert(key)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                guard !first, d.object(forKey: "sessionNotifications") as? Bool ?? true else { continue }
                if x.state == "done" {
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
}

/// The lines in the menu: one summary, and per account the done sessions with the archive hint.
struct DesktopSessionsMenuSection: View {
    @ObservedObject var mon = DesktopSessionsMonitor.shared

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
                    Text(DesktopSessionsText.hint).font(.caption)
                }
                Divider()
                Text(L("Read-only: Deploy Center archives nothing.", "Nur lesend: Deploy Center archiviert nichts."))
            }
        }
    }
}
