import SwiftUI

/// The MCP servers Claude Code sessions run on this Mac (`deploys perf mcp --json`, lib/perfmcp.sh): memory, tool calls
/// in the last 7 days and a suggestion which could be off, and where. Read-only: nothing here changes a Claude setting.
struct MCPReport: Decodable, Equatable {
    struct Server: Decodable, Equatable, Identifiable {
        var id: String { name }
        let name: String
        let processes: Int
        let mb: Int
        let sessions: Int
        let calls: Int
        let projects: Int
        let suggest: String?
        let suggestKind: String?
        let configuredIn: [String]?
        let offIn: [String]?
        let usedInNames: [String]?

        /// The suggestion in the app's language.
        func suggestion(days: Int) -> String? {
            let used = (usedInNames ?? []).map(Demo.mask).joined(separator: ", ")
            switch suggestKind {
            case "unused":
                let w = (configuredIn ?? []).map { $0 == "everywhere" ? L("everywhere", "überall") : Demo.mask($0) }.joined(separator: ", ")
                return L("could be off\(w.isEmpty ? "" : " (" + w + ")"): no tool call in \(days) days",
                         "könnte aus sein\(w.isEmpty ? "" : " (" + w + ")"): kein Tool-Aufruf in \(days) Tagen")
            case "offIn":
                let off = (offIn ?? []).map(Demo.mask).joined(separator: ", ")
                return L("off in \(off), keep in \(used)", "aus in \(off), behalten in \(used)")
            case "onlyUsed":
                return L("only in \(used) instead of everywhere", "nur in \(used) statt überall")
            default: return nil
            }
        }
    }
    let days: Int
    let servers: [Server]
}

@MainActor
final class MCPMonitor: ObservableObject {
    static let shared = MCPMonitor()
    @Published private(set) var report: MCPReport?
    private var last = Date.distantPast

    /// At most every 10 minutes (the first run reads a week of transcripts; later ones only changed files).
    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(last) >= 600 else { return }
        last = Date()
        if let r = try? await Tool.json(["perf", "mcp", "--json"], as: MCPReport.self, timeout: 180), r != report { report = r }
    }
}

/// In the performance panel: one line per running MCP server, with the suggestion under it.
struct PerfMCPSection: View {
    @ObservedObject var m = MCPMonitor.shared

    var body: some View {
        Group {
            if let r = m.report, !r.servers.isEmpty {
                Divider()
                Text(L("MCP servers (tool calls in \(r.days) days)", "MCP-Server (Tool-Aufrufe in \(r.days) Tagen)")).font(.subheadline.weight(.semibold))
                ForEach(r.servers.prefix(6)) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Demo.mask(s.name)) – \(PerfText.gb(s.mb)) · " + L("\(s.sessions) sessions · \(s.calls) calls", "\(s.sessions) Sitzungen · \(s.calls) Aufrufe"))
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                        if let sug = s.suggestion(days: r.days) {
                            Text(L("Suggestion: ", "Vorschlag: ") + sug).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Text(L("Only a report: turning a server off is yours (claude mcp remove, plugin or connector settings).",
                       "Nur ein Bericht: Abschalten entscheidest du (claude mcp remove, Plugin- oder Connector-Einstellungen)."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task { await m.refresh() }
    }
}
