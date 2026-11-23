// The summary above the list, and one row.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct Summary: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let n = store.waitingPRs, w = store.waiting.count
        let prs = Stat(value: n, label: n == 1 ? L("PR waiting", "PR wartet") : L("PRs waiting", "PRs warten"), tint: .accentColor)
        let projects = Stat(value: w, label: w == 1 ? L("project", "Projekt") : L("projects", "Projekte"), tint: .primary)
        let building = Stat(value: store.projects.filter(\.building).count, label: L("building", "bauen"), tint: .blue)
        let failed = Stat(value: store.projects.filter(\.failed).count, label: L("failed", "Fehler"), tint: .red)
        Group {
            // Four in a row get too tight from the largest standard text size on: two rows of two then.
            if size.isAccessibilitySize {
                // One column: at accessibility sizes even two stats side by side do not fit (IDEEN-12 C46).
                VStack(alignment: .leading, spacing: 10) { prs; projects; building; failed }
            } else if size >= .xxxLarge {
                Grid(verticalSpacing: 12) { GridRow { prs; projects }; GridRow { building; failed } }
            } else {
                HStack(spacing: 0) { prs; projects; building; failed }
            }
        }
        .padding(.vertical, 4)
        // One sentence instead of the numbers and words read as separate pieces.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(plural(n, ("PR", "PR"), ("PRs", "PRs"))) waiting in \(plural(w, ("project", "Projekt"), ("projects", "Projekten"))), \(store.projects.filter(\.building).count) building, \(store.projects.filter(\.failed).count) failed",
                              "\(plural(n, ("PR", "PR"), ("PRs", "PRs"))) \(n == 1 ? "wartet" : "warten") in \(plural(w, ("project", "Projekt"), ("projects", "Projekten"))), \(store.projects.filter(\.building).count) im Bau, \(store.projects.filter(\.failed).count) fehlgeschlagen"))
    }
}

struct Stat: View {
    let value: Int, label: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
}

extension PhoneProject {
    var icon: String {
        building ? "hammer.fill" : failed ? "xmark.octagon.fill" : changed ? "arrow.up.circle.fill"
            : unknown ? "questionmark.circle" : foreignRepo ? "minus.circle" : "checkmark.circle.fill"
    }
    var tint: Color { building ? .blue : failed ? .red : changed ? .accentColor : unknown ? .orange : foreignRepo ? .secondary : .green }
    var stateText: String {
        if building { return L("building", "baut") }
        if failed { return latestState.map(Self.stateWord) ?? L("failed", "fehlgeschlagen") }
        // Before `changed`: after a force push the compare fails and the count is unknown, not 0.
        if rewritten && changed { return L("history rewritten · count unknown", "Verlauf neu geschrieben · Anzahl unbekannt") }
        if changed {
            let prs = (pendingPRs ?? 0) > 0 ? plural(pendingPRs!, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast) + " · " : ""
            guard let n = pendingCommits else { return prs + L("waiting, count unknown", "wartet, Anzahl unbekannt") }
            return prs + (n == 1 ? L("1 commit waiting", "1 Commit wartet") : L("\(n) commits waiting", "\(n) Commits warten"))
        }
        if paused { return L("paused", "pausiert") }
        if rewritten { return L("history rewritten", "Verlauf neu geschrieben") }
        if let h = otherHost { return L("on \(h): not checked", "auf \(h): nicht geprüft") }
        if unknown { return L("state unknown", "Stand unbekannt") }
        if canceled { return L("up to date · last build canceled", "aktuell · letzter Build abgebrochen") }
        return L("up to date", "aktuell")
    }

    /// What goes live, for the confirmation: the newest commit, how much waits, and what it costs.
    var deploySummary: String {
        let sha = headSha.map { " (\($0.prefix(7)))" } ?? ""
        var s = headMsg.map { L("\"\($0)\"\(sha) ", "„\($0)“\(sha) ") } ?? ""
        if let n = pendingCommits, n > 0 {
            s += L("and \(plural(n, ("commit", "Commit"), ("commits", "Commits"))) in all", "und insgesamt \(plural(n, ("commit", "Commit"), ("commits", "Commits")))")
            if let k = pendingPRs, k > 0 { s += L(" from \(plural(k, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast))", " aus \(plural(k, ("PR", "PR"), ("PRs", "PRs"), atLeast: prsAtLeast))") }
            s += " "
        }
        let branch = branch ?? L("the branch", "dem Branch")
        let what = s.isEmpty ? L("The newest commit of \(branch) ", "Der neueste Commit von \(branch) ") : s
        return what + L("goes live on \(provider.rawValue). This can cost build minutes.", "geht auf \(provider.rawValue) live. Das kann Build-Minuten kosten.")
    }
}

struct Row: View {
    let p: PhoneProject
    let running: String?
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 24.0
    var body: some View {
        HStack(spacing: 12) {
            if let r = running {
                ProgressView().frame(width: iconWidth).accessibilityLabel(PhoneProject.stateWord(r))
                    .accessibilityValue(p.latestAt.map { relative($0) } ?? "")
            } else {
                Image(systemName: p.icon).foregroundStyle(p.tint).font(.title3).frame(width: iconWidth).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.body.weight(.semibold))
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var line: String {
        let state = running.map { $0 == "rollback" ? PhoneProject.stateWord($0) : L("deploying: ", "deployt: ") + PhoneProject.stateWord($0) } ?? p.stateText
        // Auto-deploy on means every push builds: the cost this app is about.
        return state + " · " + p.provider.rawValue + (p.autoDeploy ? " · " + L("auto-deploy", "Auto-Deploy") : "")
    }
}
