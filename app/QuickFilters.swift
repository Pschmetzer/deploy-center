// Deploy Center — Quick filter chips above the list (failed, waiting, running, platform) and the
// deploy-freeze note in the footer. The chips only write the search operators the list already
// understands (`is:failed`, `is:waiting`, `is:running`, `platform:x`), so a chip and typing agree.

import SwiftUI

/// What `deploys freeze --json` answers (lib/freeze.sh). An older script without `freeze` gives nothing.
struct FreezeReply: Decodable, Equatable {
    struct Rule: Decodable, Equatable {
        let n: Int?; let days: [String]?; let from: String?; let to: String?; let reason: String?
    }
    let configured: Bool?
    let closedNow: Bool?
    let reason: String?
    let rules: [Rule]?

    var ruleCount: Int { rules?.count ?? 0 }
    /// Only when closed times are set; with none there is nothing to say.
    var visible: Bool { ruleCount > 0 }
    var closed: Bool { closedNow == true }

    /// "Deploys closed: release week" or "2 closed times, open now". Demo mode leaves the reason out.
    func footerText(demo: Bool = false) -> String {
        if closed {
            let why = demo ? "" : (reason ?? "").trimmingCharacters(in: .whitespaces)
            return why.isEmpty ? L("Deploys closed", "Deploys gesperrt") : L("Deploys closed: \(why)", "Deploys gesperrt: \(why)")
        }
        return L("\(ruleCount) closed \(ruleCount == 1 ? "time" : "times"), open now",
                 "\(ruleCount) \(ruleCount == 1 ? "Sperrzeit" : "Sperrzeiten"), jetzt offen")
    }

    /// One rule as text: "fri,sat 15:00-24:00" (every day when no days are named).
    static func ruleText(_ r: Rule) -> String {
        let days = (r.days?.isEmpty ?? true) ? L("every day", "täglich") : (r.days ?? []).map { DeployWindowSettings.dayName($0.lowercased()) }.joined(separator: ",")
        return "\(days) \(r.from ?? "00:00")-\(r.to ?? "24:00")"
    }

    var help: String {
        let list = (rules ?? []).map { Self.ruleText($0) }.joined(separator: "; ")
        return L("Deploy window: \(list). Change it in Settings → Deploy → Deploy window, or with `deploys freeze`.",
                 "Deploy-Fenster: \(list). Ändern unter Einstellungen → Deploy → Deploy-Fenster oder mit `deploys freeze`.")
    }
}

/// The footer's freeze note: asks the script now and then (a menu-bar app runs for weeks).
struct FreezeNote: View {
    /// Shared with the store, so the rows can say "deploys are closed" too.
    @Binding var reply: FreezeReply?

    var body: some View {
        Group {
            if let r = reply, r.visible {
                Label(r.footerText(demo: Demo.on), systemImage: r.closed ? "lock.fill" : "lock.open")
                    .font(.caption.weight(r.closed ? .semibold : .regular))
                    .foregroundStyle(r.closed ? Color.warningText : Color.secondary)
                    .help(Demo.on ? "" : r.help)
                    .accessibilityElement(children: .combine)
            }
        }
        .task {
            while !Task.isCancelled {
                reply = try? await Tool.json(["freeze", "--json"], as: FreezeReply.self, timeout: 30)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

enum QuickFilter: CaseIterable {
    case failed, waiting, running

    var token: String {
        switch self { case .failed: return "is:failed"; case .waiting: return "is:waiting"; case .running: return "is:running" }
    }
    var title: String {
        switch self {
        case .failed: return L("Failed", "Fehler")
        case .waiting: return L("Waiting", "Wartend")
        case .running: return L("Running", "Läuft")
        }
    }
    var symbol: String {
        switch self { case .failed: return "xmark.octagon"; case .waiting: return "arrow.up.circle"; case .running: return "arrow.triangle.2.circlepath" }
    }
    /// ⌥⌘1, ⌥⌘2, ⌥⌘3 (⌥⌘4 cycles the platform).
    var key: Character {
        switch self { case .failed: return "1"; case .waiting: return "2"; case .running: return "3" }
    }

    func active(in search: String) -> Bool { SearchQuery.has(search, token) }
    func count(in items: [Item]) -> Int {
        switch self {
        case .failed: return items.filter { Row.keyFigure($0) == .failed }.count
        case .waiting: return items.filter { $0.hasNewCommits }.count
        case .running: return items.filter { $0.state.isActive }.count
        }
    }
}

extension SearchQuery {
    static func has(_ raw: String, _ token: String) -> Bool {
        raw.split(whereSeparator: { $0.isWhitespace }).contains { $0.lowercased() == token }
    }
    /// The search text with `token` added, or removed when it is there.
    static func toggled(_ raw: String, _ token: String) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.contains(where: { $0.lowercased() == token }) { return words.filter { $0.lowercased() != token }.joined(separator: " ") }
        return (words + [token]).joined(separator: " ")
    }
    /// The platform operator moved on: none, then each of `ids` in turn, then none again.
    static func cycledPlatform(_ raw: String, ids: [String]) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let isOp: (String) -> Bool = { $0.lowercased().hasPrefix("platform:") || $0.lowercased().hasPrefix("host:") }
        let current = words.first(where: isOp).map { String($0.lowercased().drop(while: { $0 != ":" }).dropFirst()) }
        let rest = words.filter { !isOp($0) }
        guard !ids.isEmpty else { return rest.joined(separator: " ") }
        let next: String?
        if let current, let i = ids.firstIndex(of: current) { next = i + 1 < ids.count ? ids[i + 1] : nil }
        else { next = ids[0] }
        return (rest + (next.map { ["platform:\($0)"] } ?? [])).joined(separator: " ")
    }
}

/// The chip row. `platforms` are the provider ids of the tabs ("vercel", "render"); one chip shows the
/// one in the search, and ⌥⌘4 or a click moves on.
struct QuickFilterBar: View {
    @Binding var search: String
    let items: [Item]
    let platforms: [String]

    var body: some View {
        let platform = SearchQuery(search).platform
        HStack(spacing: 6) {
            ForEach(QuickFilter.allCases, id: \.token) { f in
                chip(title: f.title, symbol: f.symbol, count: f.count(in: items), on: f.active(in: search),
                     help: L("Shows only these projects (⌥⌘\(String(f.key)))", "Zeigt nur diese Projekte (⌥⌘\(String(f.key)))")) {
                    search = SearchQuery.toggled(search, f.token)
                }
                .keyboardShortcut(KeyEquivalent(f.key), modifiers: [.command, .option])
            }
            if platforms.count > 1 {
                chip(title: platform.map { id in Platform.allCases.first(where: { $0.cli == id })?.rawValue ?? id } ?? L("Platform", "Plattform"),
                     symbol: "server.rack", count: nil, on: platform != nil,
                     help: L("Cycles through the platforms (⌥⌘4)", "Wechselt durch die Plattformen (⌥⌘4)")) {
                    search = SearchQuery.cycledPlatform(search, ids: platforms)
                }
                .keyboardShortcut("4", modifiers: [.command, .option])
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func chip(title: String, symbol: String, count: Int?, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.caption.weight(on ? .semibold : .regular))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title + (count.map { $0 > 0 ? ", \($0)" : "" } ?? ""))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
