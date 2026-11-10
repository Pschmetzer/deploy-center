// Deploy Center — Savings: the simulator (what auto-deploy would cost, before anything is turned off)
// and the ledger (what turning it off saved since). Both read `deploys simulate --json` and
// `deploys ledger --json` (lib/savings.sh). Every number here is an estimate and shows "≈".
//
// Hooks into the rest of the app, kept to two: `SavingsEntry` under the cost bar in the main
// window (a first-run banner, later the ledger total) and `SavingsLink` in Settings > Costs.

import SwiftUI
import AppKit

// MARK: - Lenient decoding (a missing or odd field is "unknown", never a failed sheet)

fileprivate struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// An element that could not be read becomes nil and is dropped, instead of failing the whole list.
fileprivate struct Skippable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

fileprivate struct Lax {
    let c: KeyedDecodingContainer<AnyKey>?
    init(_ d: Decoder) { c = try? d.container(keyedBy: AnyKey.self) }
    init(container: KeyedDecodingContainer<AnyKey>?) { c = container }

    func num(_ k: String) -> Double? {
        guard let c else { return nil }
        if let d = try? c.decodeIfPresent(Double.self, forKey: AnyKey(k)) { return d }
        // A number sent as text still counts.
        if let s = try? c.decodeIfPresent(String.self, forKey: AnyKey(k)) { return Double(s) }
        return nil
    }
    func str(_ k: String) -> String? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(String.self, forKey: AnyKey(k))
    }
    func bool(_ k: String) -> Bool? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(Bool.self, forKey: AnyKey(k))
    }
    func obj<T: Decodable>(_ k: String) -> T? {
        guard let c else { return nil }
        return try? c.decodeIfPresent(T.self, forKey: AnyKey(k))
    }
    func list<T: Decodable>(_ k: String) -> [T] {
        guard let c, let raw = try? c.decodeIfPresent([Skippable<T>].self, forKey: AnyKey(k)) else { return [] }
        return raw.compactMap { $0.value }
    }
    func sub(_ k: String) -> Lax {
        guard let c else { return Lax(container: nil) }
        return Lax(container: try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(k)))
    }
}

// MARK: - What the script says

/// Builds, minutes and dollars for one stretch of time. Any of them may be unknown.
struct SavingsAmount: Decodable {
    var builds: Double? = nil
    var minutes: Double? = nil
    var usd: Double? = nil
    var vercelMinutes: Double? = nil
    var renderMinutes: Double? = nil
    init() {}
    init(from decoder: Decoder) throws {
        let l = Lax(decoder)
        builds = l.num("builds"); minutes = l.num("minutes"); usd = l.num("usd")
        vercelMinutes = l.num("vercelMinutes"); renderMinutes = l.num("renderMinutes")
    }
}

struct SimulateReport: Decodable {
    struct Row: Decodable, Identifiable {
        let platform: String, name: String, auto: Bool, unit: String
        let basis: String?, problem: String?
        let pushes: Double, activeDays: Double, pushesPerDay: Double?
        let avgBuildMinutes: Double?, usdPerBuild: Double?, priceSource: String?
        let autoMonth: SavingsAmount, dailyMonth: SavingsAmount, savingMonth: SavingsAmount
        var id: String { platform + "/" + name }

        init(from decoder: Decoder) throws {
            let l = Lax(decoder)
            guard let n = l.str("name"), !n.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a row without a name"))
            }
            let plat = l.str("platform") ?? "vercel"
            name = n; platform = plat; auto = l.bool("auto") ?? false
            unit = l.str("unit") ?? (plat == "render" ? "pipeline minutes" : "build minutes")
            basis = l.str("basis"); problem = l.str("problem")
            pushes = l.num("pushes") ?? 0; activeDays = l.num("activeDays") ?? 0; pushesPerDay = l.num("pushesPerDay")
            avgBuildMinutes = l.num("avgBuildMinutes"); usdPerBuild = l.num("usdPerBuild"); priceSource = l.str("priceSource")
            autoMonth = l.obj("autoMonth") ?? SavingsAmount()
            dailyMonth = l.obj("dailyMonth") ?? SavingsAmount()
            savingMonth = l.obj("savingMonth") ?? SavingsAmount()
        }
    }
    let days: Double, method: String, generatedAt: Double?
    let projects: [Row]
    let autoMonth: SavingsAmount, dailyMonth: SavingsAmount, savingMonth: SavingsAmount
    /// False when a project with pushes has no price: the dollar totals leave it out.
    let usdComplete: Bool

    init(from decoder: Decoder) throws {
        let l = Lax(decoder), t = l.sub("total")
        days = l.num("days") ?? 30; method = l.str("method") ?? ""; generatedAt = l.num("generatedAt")
        projects = l.list("projects")
        autoMonth = t.obj("autoMonth") ?? SavingsAmount()
        dailyMonth = t.obj("dailyMonth") ?? SavingsAmount()
        savingMonth = t.obj("savingMonth") ?? SavingsAmount()
        usdComplete = t.bool("usdComplete") ?? true
    }
}

struct LedgerReport: Decodable {
    struct SkippedPush: Decodable { let day: String; let sha: String
        init(from decoder: Decoder) throws { let l = Lax(decoder); day = l.str("day") ?? ""; sha = l.str("sha") ?? "" }
    }
    struct Row: Decodable, Identifiable {
        let platform: String, name: String, unit: String, offDay: String?
        let basis: String?, problem: String?
        let pushes: Double, builds: Double, skipped: Double
        let avgBuildMinutes: Double?, usdPerBuild: Double?, priceSource: String?
        let savedMinutes: Double?, savedUsd: Double?
        let skippedPushes: [SkippedPush]
        var id: String { platform + "/" + name }

        init(from decoder: Decoder) throws {
            let l = Lax(decoder)
            guard let n = l.str("name"), !n.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a row without a name"))
            }
            let plat = l.str("platform") ?? "vercel"
            name = n; platform = plat
            unit = l.str("unit") ?? (plat == "render" ? "pipeline minutes" : "build minutes")
            offDay = l.str("offDay"); basis = l.str("basis"); problem = l.str("problem")
            pushes = l.num("pushes") ?? 0; builds = l.num("builds") ?? 0; skipped = l.num("skipped") ?? 0
            avgBuildMinutes = l.num("avgBuildMinutes"); usdPerBuild = l.num("usdPerBuild"); priceSource = l.str("priceSource")
            savedMinutes = l.num("savedMinutes"); savedUsd = l.num("savedUsd")
            skippedPushes = l.list("skippedPushes")
        }
    }
    let since: String?, days: Double, method: String
    let projects: [Row]
    let skipped: Double, pushes: Double, builds: Double
    let usd: Double?, builtUsd: Double?, vercelMinutes: Double, renderMinutes: Double, usdComplete: Bool

    init(from decoder: Decoder) throws {
        let l = Lax(decoder), t = l.sub("total")
        since = l.str("since"); days = l.num("days") ?? 0; method = l.str("method") ?? ""
        projects = l.list("projects")
        skipped = t.num("skipped") ?? 0; pushes = t.num("pushes") ?? 0; builds = t.num("builds") ?? 0
        usd = t.num("usd"); builtUsd = t.num("builtUsd")
        vercelMinutes = t.num("vercelMinutes") ?? 0; renderMinutes = t.num("renderMinutes") ?? 0
        usdComplete = t.bool("usdComplete") ?? true
    }

    /// Something was turned off here: there is a ledger to show.
    var hasStarted: Bool { since != nil }

    /// Per day for the share card: what builds would have cost (skipped + built) and what the
    /// builds that ran cost. Only after a whole day and with a price.
    var perDay: (before: Double, after: Double)? {
        guard days >= 1, let usd, usd > 0 else { return nil }
        let built = builtUsd ?? 0
        return ((usd + built) / days, built / days)
    }
}

// MARK: - Loading (shared by the banner, Settings and the sheet)

@MainActor
final class SavingsModel: ObservableObject {
    static let shared = SavingsModel()

    @Published var simulation: SimulateReport?
    @Published var ledger: LedgerReport?
    @Published var loadingSimulation = false
    @Published var loadingLedger = false
    @Published var simulationError: String?
    @Published var ledgerError: String?
    @Published var simulatedAt: Date?
    @Published var ledgerAt: Date?

    private let defaults = UserDefaults.standard

    private init() {
        // The last answers stay for the next start: both take many API calls.
        if let d = defaults.data(forKey: "savingsSimulation") { simulation = try? JSONDecoder().decode(SimulateReport.self, from: d) }
        if let d = defaults.data(forKey: "savingsLedger") { ledger = try? JSONDecoder().decode(LedgerReport.self, from: d) }
        let s = defaults.double(forKey: "savingsSimulationAt"), g = defaults.double(forKey: "savingsLedgerAt")
        simulatedAt = s > 0 ? Date(timeIntervalSince1970: s) : nil
        ledgerAt = g > 0 ? Date(timeIntervalSince1970: g) : nil
    }

    func loadSimulation(days: Int = 30) async {
        guard !loadingSimulation else { return }
        loadingSimulation = true; defer { loadingSimulation = false }
        do {
            let data = try await Tool.run(["simulate", "--json", "--days", "\(days)"], timeout: 300)
            simulation = try Self.decode(SimulateReport.self, data, what: "simulate")
            simulationError = nil; simulatedAt = Date()
            defaults.set(data, forKey: "savingsSimulation"); defaults.set(Date().timeIntervalSince1970, forKey: "savingsSimulationAt")
        } catch is CancellationError {
        } catch { simulationError = error.localizedDescription }
    }

    func loadLedger() async {
        guard !loadingLedger else { return }
        loadingLedger = true; defer { loadingLedger = false }
        do {
            let data = try await Tool.run(["ledger", "--json"], timeout: 300)
            ledger = try Self.decode(LedgerReport.self, data, what: "ledger")
            ledgerError = nil; ledgerAt = Date()
            defaults.set(data, forKey: "savingsLedger"); defaults.set(Date().timeIntervalSince1970, forKey: "savingsLedgerAt")
        } catch is CancellationError {
        } catch { ledgerError = error.localizedDescription }
    }

    /// The ledger again when the last one is older than half a day.
    func refreshLedgerIfOld() async {
        if let at = ledgerAt, Date().timeIntervalSince(at) < 12 * 3600 { return }
        await loadLedger()
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ data: Data, what: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            Log.write("deploys \(what): unexpected answer (\(error)); it began: \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw ToolError(message: L("Unexpected answer from deploys \(what) – details in the log.",
                                       "Unerwartete Antwort von deploys \(what) – Details im Log."))
        }
    }
}

// MARK: - Formatting

enum SavingsFormat {
    static func usd(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "≈ " + v.formatted(.currency(code: "USD"))
    }
    static func usdShort(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "≈ " + v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2)))
    }
    static func minutes(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "≈ " + Int(v.rounded()).formatted()
    }
    /// "≈ 2.5" (one decimal at most), with a suffix such as " min".
    static func approx(_ v: Double?, suffix: String = "") -> String {
        guard let v else { return "–" }
        return "≈ " + v.formatted(.number.precision(.fractionLength(0...1))) + suffix
    }
    static func count(_ v: Double) -> String {
        v == v.rounded() ? Int(v).formatted() : v.formatted(.number.precision(.fractionLength(1)))
    }
    /// "build minutes" / "pipeline minutes" in the reader's language.
    static func unit(_ u: String) -> String {
        u.hasPrefix("pipeline") ? L("pipeline minutes", "Pipeline-Minuten") : L("build minutes", "Build-Minuten")
    }
    /// "2026-01-20" as a date for the reader.
    static func day(_ s: String?) -> String {
        guard let s else { return "–" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
    static func name(_ n: String) -> String { Demo.mask(n) }
    static func problem(_ p: String) -> String {
        if p.hasPrefix("GitHub") { return L("GitHub could not be read (is gh logged in?)", "GitHub nicht lesbar (ist gh angemeldet?)") }
        if p.hasPrefix("no GitHub repo") { return L("no GitHub repo and branch known", "kein GitHub-Repo und Branch bekannt") }
        if p.hasPrefix("no finished build") { return L("no finished build to measure", "kein fertiger Build zum Messen") }
        return p
    }
    static func basis(_ b: String?) -> String? {
        b == "commits" ? L("commits counted (GitHub pushes not readable): an upper bound",
                           "Commits gezählt (GitHub-Pushes nicht lesbar): eine Obergrenze") : nil
    }
}

// MARK: - The two hooks

/// Under the cost bar: before anything was turned off an offer to simulate, afterwards the ledger total.
/// "1 build", "≈ 3 builds": the word that fits a formatted count ("1" is the only singular).
private func counted(_ formatted: String, _ one: String, _ other: String) -> String { formatted + " " + (formatted == "1" ? one : other) }

/// Nothing saved yet: under a minute and no skipped build. Then the app says so plainly.
private func nothingSaved(_ l: LedgerReport) -> Bool { l.vercelMinutes + l.renderMinutes < 1 && l.skipped < 1 && (l.usd ?? 0) < 0.01 }

struct SavingsEntry: View {
    @ObservedObject var store: Store
    @ObservedObject private var model = SavingsModel.shared
    @AppStorage("savingsBannerDismissed") private var dismissed = false
    @State private var sheet: SavingsSheet.Tab?
    @Environment(\.colorSchemeContrast) private var contrast

    private var items: [Item] { Platform.allCases.flatMap { store.items[$0] ?? [] } }
    /// Auto-deploy was turned off here at least once.
    private var everOff: Bool { store.costs?.offDay != nil || model.ledger?.hasStarted == true }

    var body: some View {
        Group {
            if let l = model.ledger, l.hasStarted {
                ledgerLine(l)
            } else if everOff {
                // Only after it was turned off here: someone who never had it on has nothing to see.
                bar(icon: "chart.line.downtrend.xyaxis", text: L("Auto-deploy is off. See what it saved so far.",
                                                                "Auto-Deploy ist aus. Sieh nach, was es bisher gespart hat."),
                    button: L("Ledger …", "Bilanz …")) { sheet = .ledger }
            } else if !dismissed, items.contains(where: { $0.auto }) {
                bar(icon: "sparkles", text: L("What does auto-deploy cost you? Simulate it before you switch anything off.",
                                              "Was kostet dich Auto-Deploy? Simuliere es, bevor du etwas ausschaltest."),
                    button: L("Simulate …", "Simulieren …"), close: { dismissed = true }) { sheet = .simulator }
            }
        }
        .sheet(item: $sheet) { tab in SavingsSheet(start: tab) }
        .task(id: everOff) { if everOff { await model.refreshLedgerIfOld() } }
    }

    @ViewBuilder private func ledgerLine(_ l: LedgerReport) -> some View {
        if nothingSaved(l) {
            // No green bar for a saving of zero.
            bar(icon: "leaf", text: L("Since \(SavingsFormat.day(l.since)) nothing saved yet – that takes a push",
                                      "Seit \(SavingsFormat.day(l.since)) noch nichts gespart – dafür braucht es einen Push"),
                button: L("Ledger …", "Bilanz …"), neutral: true) { sheet = .ledger }
        } else {
            let m = SavingsFormat.minutes(l.vercelMinutes + l.renderMinutes)
            let amount = (l.usd ?? 0) > 0 ? SavingsFormat.usdShort(l.usd) : L(counted(m, "minute", "minutes"), counted(m, "Minute", "Minuten"))
            let skipped = SavingsFormat.count(l.skipped)
            bar(icon: "leaf", text: L("\(amount) saved since \(SavingsFormat.day(l.since)) · \(counted(skipped, "build", "builds")) skipped",
                                      "\(amount) gespart seit \(SavingsFormat.day(l.since)) · \(counted(skipped, "Build", "Builds")) übersprungen"),
                button: L("Ledger …", "Bilanz …")) { sheet = .ledger }
        }
    }

    private func bar(icon: String, text: String, button: String, neutral: Bool = false, close: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(neutral ? Color.secondary : Color.green)
            Text(text).font(.callout)
            Spacer()
            Button(button, action: action).buttonStyle(.link)
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L("Close", "Schließen")).accessibilityLabel(L("Close", "Schließen"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background((neutral ? Color.secondary : Color.green).opacity(contrast == .increased ? 0.2 : 0.08))
    }
}

/// Settings > Costs: the way to the simulator and the ledger at any time.
struct SavingsLink: View {
    @ObservedObject private var model = SavingsModel.shared
    @State private var sheet: SavingsSheet.Tab?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Savings", "Ersparnis"))
                Text(L("Estimate what auto-deploy costs, and what turning it off saved.",
                       "Schätzt, was Auto-Deploy kostet und was das Ausschalten gespart hat."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Simulator …", "Simulator …")) { sheet = .simulator }
            Button(L("Ledger …", "Bilanz …")) { sheet = .ledger }
        }
        .sheet(item: $sheet) { tab in SavingsSheet(start: tab) }
    }
}

// MARK: - The sheet

struct SavingsSheet: View {
    enum Tab: String, Identifiable, CaseIterable { case simulator, ledger; var id: String { rawValue } }
    @State private var tab: Tab
    @Environment(\.dismiss) private var dismiss

    init(start: Tab) { _tab = State(initialValue: start) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("Savings view", "Ersparnis-Ansicht"), selection: $tab) {
                    Text(L("Simulator", "Simulator")).tag(Tab.simulator)
                    Text(L("Ledger", "Bilanz")).tag(Tab.ledger)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                Button(L("Done", "Fertig")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                switch tab {
                case .simulator: SimulatorView()
                case .ledger: LedgerView(showSimulator: { tab = .simulator })
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 500, idealHeight: 600)
    }
}

/// "How this is estimated", folded away, and the state of the last load.
private struct EstimateFooter: View {
    let method: String
    let at: Date?
    let loading: Bool
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(L("How this is estimated", "Wie das geschätzt wird")) {
                Text(L(method.isEmpty ? "Pushes on the deploy branch times the average build of each project." : method,
                       "Schätzung: Pushes auf den Deploy-Branch mal der durchschnittliche Build jedes Projekts. Minuten aus den letzten fertigen Builds (bis zu 20), Dollar aus Vercels Abrechnung pro Build (7 Tage), sonst aus dem Minutenpreis des Teams, sonst aus DEPLOYS_VERCEL_USD_PER_MIN / DEPLOYS_RENDER_USD_PER_MIN. Wo GitHub keine Pushes liefert, werden Commits gezählt (eine Obergrenze)."))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            HStack {
                if let at {
                    Text(L("Estimated ", "Geschätzt ") + at.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(L("Estimate again", "Neu schätzen"), action: reload).disabled(loading)
            }
        }
    }
}

// MARK: - Simulator

struct SimulatorView: View {
    @ObservedObject private var model = SavingsModel.shared
    @AppStorage("savingsDays") private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let s = model.simulation {
                report(s)
            } else if model.loadingSimulation {
                loading
            } else {
                start
            }
            if let e = model.simulationError { ErrorText(e) }
            if let s = model.simulation {
                EstimateFooter(method: s.method, at: model.simulatedAt, loading: model.loadingSimulation) {
                    Task { await model.loadSimulation(days: days) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("What would auto-deploy cost?", "Was würde Auto-Deploy kosten?")).font(.title2.weight(.semibold))
            Text(L("Counts the pushes to each project's deploy branch on GitHub and prices each as one build, at the project's average. Nothing is changed.",
                   "Zählt die Pushes auf den Deploy-Branch jedes Projekts auf GitHub und rechnet jeden als einen Build zum Durchschnitt des Projekts. Es wird nichts geändert."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(L("Look back", "Zurückschauen"), selection: $days) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text(L("\($0) days", "\($0) Tage")).tag($0) }
                }
                .frame(width: 220)
                Button(L("Simulate", "Simulieren")) { Task { await model.loadSimulation(days: days) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Counting pushes and measuring builds … (this takes a minute)", "Zähle Pushes und messe Builds … (das dauert eine Minute)"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func report(_ s: SimulateReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Estimate from the last \(Int(s.days)) days, per month", "Schätzung aus den letzten \(Int(s.days)) Tagen, pro Monat"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                headline(L("Auto-deploy would cost", "Auto-Deploy würde kosten"), s.autoMonth, color: .red)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                headline(L("Deploying once a day", "Einmal am Tag deployen"), s.dailyMonth, color: .green)
            }
            if let d = s.savingMonth.usd, d > 0 {
                Text(L("\(SavingsFormat.usdShort(d)) a month less", "\(SavingsFormat.usdShort(d)) im Monat weniger"))
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
            }
            if !s.usdComplete {
                Text(L("Some projects have no price yet (Render has no billing API: set DEPLOYS_RENDER_USD_PER_MIN). Their minutes count, their dollars do not.",
                       "Manche Projekte haben noch keinen Preis (Render hat keine Abrechnungs-API: DEPLOYS_RENDER_USD_PER_MIN setzen). Ihre Minuten zählen, ihre Dollar nicht."))
                    .font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text(L("Project", "Projekt")); Text(L("Pushes/day", "Pushes/Tag")); Text(L("Build", "Build"))
                Text(L("Auto-deploy", "Auto-Deploy")); Text(L("Once a day", "1× am Tag"))
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(s.projects) { r in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(SavingsFormat.name(r.name)).lineLimit(1)
                            Text(providerLabel(r.platform)).font(.caption2).foregroundStyle(.secondary)
                            if !r.auto { Text(L("off", "aus")).font(.caption2).foregroundStyle(.green) }
                        }
                        if let p = r.problem { Text(SavingsFormat.problem(p)).font(.caption2).foregroundStyle(Color.warningText) }
                        else if let b = SavingsFormat.basis(r.basis) { Text(b).font(.caption2).foregroundStyle(.secondary) }
                    }
                    // VoiceOver reads the row as one sentence, not five loose cells.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowSentence(r))
                    Text(SavingsFormat.approx(r.pushesPerDay)).monospacedDigit().accessibilityHidden(true)
                    Text(SavingsFormat.approx(r.avgBuildMinutes, suffix: " min")).monospacedDigit().accessibilityHidden(true)
                    amount(r.autoMonth, unit: r.unit).accessibilityHidden(true)
                    amount(r.dailyMonth, unit: r.unit).accessibilityHidden(true)
                }
            }
        }
        .font(.callout)
    }

    private func rowSentence(_ r: SimulateReport.Row) -> String {
        L("\(SavingsFormat.name(r.name)), \(providerLabel(r.platform))\(r.auto ? "" : ", auto-deploy off"): \(SavingsFormat.approx(r.pushesPerDay)) pushes a day, builds of \(SavingsFormat.approx(r.avgBuildMinutes, suffix: " min")); auto-deploy \(SavingsFormat.usd(r.autoMonth.usd)) a month, once a day \(SavingsFormat.usd(r.dailyMonth.usd))",
          "\(SavingsFormat.name(r.name)), \(providerLabel(r.platform))\(r.auto ? "" : ", Auto-Deploy aus"): \(SavingsFormat.approx(r.pushesPerDay)) Pushes am Tag, Builds von \(SavingsFormat.approx(r.avgBuildMinutes, suffix: " min")); Auto-Deploy \(SavingsFormat.usd(r.autoMonth.usd)) im Monat, einmal am Tag \(SavingsFormat.usd(r.dailyMonth.usd))")
    }

    private func headline(_ title: String, _ a: SavingsAmount, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(SavingsFormat.usdShort(a.usd)).font(.largeTitle.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(minutesLine(a)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func minutesLine(_ a: SavingsAmount) -> String {
        var parts: [String] = []
        if let v = a.vercelMinutes, v > 0 { parts.append(SavingsFormat.minutes(v) + " " + L("Vercel build minutes", "Vercel-Build-Minuten")) }
        if let r = a.renderMinutes, r > 0 { parts.append(SavingsFormat.minutes(r) + " " + L("Render pipeline minutes", "Render-Pipeline-Minuten")) }
        if let b = a.builds { let c = SavingsFormat.count(b); parts.append("≈ " + L(counted(c, "build", "builds"), counted(c, "Build", "Builds"))) }
        return parts.joined(separator: " · ")
    }

    private func amount(_ a: SavingsAmount, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(SavingsFormat.usd(a.usd)).monospacedDigit()
            Text(SavingsFormat.minutes(a.minutes) + " " + SavingsFormat.unit(unit)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ledger

struct LedgerView: View {
    let showSimulator: () -> Void
    @ObservedObject private var model = SavingsModel.shared
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let l = model.ledger, l.hasStarted {
                report(l)
            } else if model.loadingLedger {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Counting the pushes that did not build …", "Zähle die Pushes, die nicht gebaut haben …")).foregroundStyle(.secondary)
                }
            } else if model.ledger != nil {
                notStarted
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("What did turning off auto-deploy save?", "Was hat das Ausschalten von Auto-Deploy gespart?")).font(.title2.weight(.semibold))
                    Text(L("Counts the pushes since then that did not build, at each project's average build.",
                           "Zählt die Pushes seitdem, die nicht gebaut haben, zum durchschnittlichen Build jedes Projekts."))
                        .foregroundStyle(.secondary)
                    Button(L("Show the ledger", "Bilanz zeigen")) { Task { await model.loadLedger() } }.buttonStyle(.borderedProminent)
                }
            }
            if let e = model.ledgerError { ErrorText(e) }
            if let l = model.ledger {
                EstimateFooter(method: l.method, at: model.ledgerAt, loading: model.loadingLedger) {
                    Task { await model.loadLedger() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notStarted: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Nothing turned off yet", "Noch nichts ausgeschaltet")).font(.title2.weight(.semibold))
            Text(L("The ledger starts on the day auto-deploy is turned off for the first project. The simulator shows what that could save.",
                   "Die Bilanz beginnt am Tag, an dem Auto-Deploy für das erste Projekt ausgeschaltet wird. Der Simulator zeigt, was das sparen könnte."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("Open the simulator", "Simulator öffnen"), action: showSimulator)
        }
    }

    @ViewBuilder private func report(_ l: LedgerReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if nothingSaved(l) {
                // A zero is not celebrated in 40 pt green.
                Text(L("Nothing saved yet", "Noch nichts gespart")).font(.title2.weight(.semibold))
                Text(L("It takes a push to a project with auto-deploy off: that build is then skipped and counted here.",
                       "Es braucht einen Push auf ein Projekt mit ausgeschaltetem Auto-Deploy: dieser Build wird dann übersprungen und hier gezählt."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(bigNumber(l))
                    .font(.system(size: 40, weight: .bold).monospacedDigit()).foregroundStyle(.green)
            }
            Text(L("since \(SavingsFormat.day(l.since))", "seit \(SavingsFormat.day(l.since))")).font(.title3).foregroundStyle(.secondary)
            Text(totalsLine(l)).font(.callout).foregroundStyle(.secondary)
            if !l.usdComplete {
                Text(L("Some skipped builds have no price (Render: set DEPLOYS_RENDER_USD_PER_MIN); their minutes count, their dollars do not.",
                       "Manche übersprungenen Builds haben keinen Preis (Render: DEPLOYS_RENDER_USD_PER_MIN setzen); ihre Minuten zählen, ihre Dollar nicht."))
                    .font(.caption).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true)
            }
            if let d = l.perDay, d.before > d.after {
                Button(L("Share the saving …", "Ersparnis teilen …")) { sharing = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $sharing) { SavingShare(before: d.before, after: d.after) }
                    .help(L("Copies a picture and a sentence with your saving, without project names",
                            "Kopiert ein Bild und einen Satz mit deiner Ersparnis, ohne Projektnamen"))
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(l.projects) { r in LedgerRow(row: r) }
        }
    }

    /// "≈ $12.40 saved", or the minutes when no build has a price.
    private func bigNumber(_ l: LedgerReport) -> String {
        if let usd = l.usd, l.usdComplete || usd > 0 {
            return L("\(SavingsFormat.usdShort(usd)) saved", "\(SavingsFormat.usdShort(usd)) gespart")
        }
        let m = SavingsFormat.minutes(l.vercelMinutes + l.renderMinutes)
        return L(counted(m, "minute", "minutes") + " saved", counted(m, "Minute", "Minuten") + " gespart")
    }

    private func totalsLine(_ l: LedgerReport) -> String {
        let s = SavingsFormat.count(l.skipped), p = SavingsFormat.count(l.pushes)
        var parts = [L("≈ \(counted(s, "build", "builds")) skipped of \(counted(p, "push", "pushes"))",
                       "≈ \(counted(s, "Build", "Builds")) übersprungen von \(counted(p, "Push", "Pushes"))")]
        if l.vercelMinutes > 0 { parts.append(SavingsFormat.minutes(l.vercelMinutes) + " " + L("Vercel build minutes", "Vercel-Build-Minuten")) }
        if l.renderMinutes > 0 { parts.append(SavingsFormat.minutes(l.renderMinutes) + " " + L("Render pipeline minutes", "Render-Pipeline-Minuten")) }
        return parts.joined(separator: " · ")
    }
}

private struct LedgerRow: View {
    let row: LedgerReport.Row

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                if row.skippedPushes.isEmpty {
                    Text(L("No skipped push yet.", "Noch kein übersprungener Push.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(row.skippedPushes.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 8) {
                        Text(SavingsFormat.day(p.day)).frame(width: 110, alignment: .leading)
                        Text(p.sha).font(.caption.monospaced())
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if row.skipped > Double(row.skippedPushes.count) {
                    Text(L("… and \(SavingsFormat.count(row.skipped - Double(row.skippedPushes.count))) earlier",
                           "… und \(SavingsFormat.count(row.skipped - Double(row.skippedPushes.count))) frühere"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let b = SavingsFormat.basis(row.basis) { Text(b).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(SavingsFormat.name(row.name)).lineLimit(1)
                        Text(providerLabel(row.platform)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(L("off since \(SavingsFormat.day(row.offDay)) · \(SavingsFormat.count(row.skipped)) of \(SavingsFormat.count(row.pushes)) pushes not built",
                           "aus seit \(SavingsFormat.day(row.offDay)) · \(SavingsFormat.count(row.skipped)) von \(SavingsFormat.count(row.pushes)) Pushes nicht gebaut"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let p = row.problem { Text(SavingsFormat.problem(p)).font(.caption2).foregroundStyle(Color.warningText) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(SavingsFormat.usd(row.savedUsd)).monospacedDigit().foregroundStyle(row.savedUsd == nil ? .secondary : .primary)
                    Text(SavingsFormat.minutes(row.savedMinutes) + " " + SavingsFormat.unit(row.unit)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
