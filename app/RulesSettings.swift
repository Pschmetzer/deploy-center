// Deploy Center — Settings > Deploy & guard > Rules: "when … then …" for what waits, kept in
// ~/.config/deploys/rules.json for `deploys` to apply. The app only edits the file; it never
// deploys by a rule itself. Keys the app does not know stay as they are when it is saved.
//
// {"rules":[{"name":"Docs go out by themselves","enabled":true,
//            "when":{"projects":["vercel/site"],"ciGreen":true,"paths":["docs/**","*.md"],"onlyPaths":true,
//                    "labels":["ship"],"minAgeHours":2},
//            "then":"deploy"}]}
// then: "deploy" (start it), "hold" (keep it back, also from deploy-changed), "notify" (only say so).
// Every condition given must hold; one not given holds always.

import SwiftUI

struct RulesConfig: Equatable {
    enum Action: String, CaseIterable, Identifiable {
        case deploy, hold, notify
        var id: String { rawValue }
        var title: String {
            switch self {
            case .deploy: return L("deploy it", "deployen")
            case .hold: return L("hold it back", "zurückhalten")
            case .notify: return L("only notify", "nur melden")
            }
        }
    }
    struct Rule: Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var enabled = true
        var projects: [String] = []     // "vercel/<name>"; empty: every project
        var ciGreen = false
        var paths: [String] = []        // globs of changed files
        var onlyPaths = false           // every changed file matches `paths`, not only one
        var labels: [String] = []       // a PR label of the waiting commits
        var minAgeHours: Int? = nil     // the oldest waiting commit is at least this old
        var then: Action = .notify
        /// Keys of this rule the app does not know, written back unchanged.
        var extra: [String: Any] = [:]
        var extraWhen: [String: Any] = [:]
        static func == (a: Rule, b: Rule) -> Bool {
            a.name == b.name && a.enabled == b.enabled && a.projects == b.projects && a.ciGreen == b.ciGreen && a.paths == b.paths
                && a.onlyPaths == b.onlyPaths && a.labels == b.labels && a.minAgeHours == b.minAgeHours && a.then == b.then
                && NSDictionary(dictionary: a.extra).isEqual(to: b.extra) && NSDictionary(dictionary: a.extraWhen).isEqual(to: b.extraWhen)
        }
    }
    var rules: [Rule] = []

    static var url: URL {
        let dir = ProcessInfo.processInfo.environment["DEPLOYS_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/deploys")
        return dir.appendingPathComponent("rules.json")
    }

    /// Why the rules cannot be saved, or nil.
    var problem: String? {
        for r in rules {
            if r.name.trimmingCharacters(in: .whitespaces).isEmpty { return L("Every rule needs a name", "Jede Regel braucht einen Namen") }
            if r.onlyPaths && r.paths.isEmpty { return L("\"Only these files\" needs file patterns", "„Nur diese Dateien“ braucht Dateimuster") }
            if let h = r.minAgeHours, h < 0 { return L("An age is 0 hours or more", "Ein Alter ist 0 Stunden oder mehr") }
            // A rule that deploys with no condition at all would ship every push: auto-deploy again.
            if r.then == .deploy && !r.ciGreen && r.paths.isEmpty && r.labels.isEmpty && r.minAgeHours == nil {
                return L("\"\(r.name)\" would deploy everything: give it a condition", "„\(r.name)“ würde alles deployen: gib ihr eine Bedingung")
            }
        }
        return nil
    }

    static func list(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parse(_ data: Data?) -> RulesConfig {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rules = root["rules"] as? [[String: Any]] else { return RulesConfig() }
        let known: Set<String> = ["name", "enabled", "when", "then"]
        let knownWhen: Set<String> = ["projects", "ciGreen", "paths", "onlyPaths", "labels", "minAgeHours"]
        return RulesConfig(rules: rules.map { r in
            let w = r["when"] as? [String: Any] ?? [:]
            return Rule(name: r["name"] as? String ?? "", enabled: r["enabled"] as? Bool ?? true,
                        projects: w["projects"] as? [String] ?? [], ciGreen: w["ciGreen"] as? Bool ?? false,
                        paths: w["paths"] as? [String] ?? [], onlyPaths: w["onlyPaths"] as? Bool ?? false,
                        labels: w["labels"] as? [String] ?? [], minAgeHours: w["minAgeHours"] as? Int,
                        then: Action(rawValue: r["then"] as? String ?? "") ?? .notify,
                        extra: r.filter { !known.contains($0.key) }, extraWhen: w.filter { !knownWhen.contains($0.key) })
        })
    }

    /// The file's text with `rules` replaced; other top-level keys of `old` are kept.
    func encoded(over old: Data?) throws -> Data {
        var root = old.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        root["rules"] = rules.map { r -> [String: Any] in
            var w = r.extraWhen
            if !r.projects.isEmpty { w["projects"] = r.projects }
            if r.ciGreen { w["ciGreen"] = true }
            if !r.paths.isEmpty { w["paths"] = r.paths }
            if r.onlyPaths { w["onlyPaths"] = true }
            if !r.labels.isEmpty { w["labels"] = r.labels }
            if let h = r.minAgeHours { w["minAgeHours"] = h }
            var o = r.extra
            o["name"] = r.name; o["enabled"] = r.enabled; o["when"] = w; o["then"] = r.then.rawValue
            return o
        }
        var d = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    static func load() -> RulesConfig { parse(try? Data(contentsOf: url)) }
    /// An error text when it failed; a file that is not valid JSON is never written over.
    func save() -> String? {
        if let p = problem { return p }
        let u = Self.url
        let old = try? Data(contentsOf: u)
        if DeployWindowConfig.unreadable(old) {
            return L("rules.json is not valid JSON; nothing was changed. Fix it by hand first.",
                     "rules.json ist kein gültiges JSON; es wurde nichts geändert. Erst von Hand korrigieren.")
        }
        if rules.isEmpty && old == nil { return nil }
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded(over: old).write(to: u, options: .atomic)
            return nil
        } catch { return error.localizedDescription }
    }

    /// "When CI is green and only docs/** changed: deploy it".
    static func summary(_ r: Rule) -> String {
        var c: [String] = []
        if !r.projects.isEmpty { c.append(L("for ", "für ") + r.projects.map { String($0.split(separator: "/").last ?? "") }.joined(separator: ", ")) }
        if r.ciGreen { c.append(L("CI is green", "CI grün ist")) }
        if !r.paths.isEmpty { c.append((r.onlyPaths ? L("only ", "nur ") : "") + r.paths.joined(separator: ", ") + L(" changed", " geändert")) }
        if !r.labels.isEmpty { c.append(L("a PR has ", "ein PR hat ") + r.labels.joined(separator: ", ")) }
        if let h = r.minAgeHours { c.append(L("it waits \(h) h or more", "es \(h) h oder länger wartet")) }
        return (c.isEmpty ? L("Always", "Immer") : L("When ", "Wenn ") + c.joined(separator: L(" and ", " und "))) + ": " + r.then.title
    }
}

struct RulesSettings: View {
    @State private var config = RulesConfig.load()
    @State private var saved = RulesConfig.load()
    @State private var error: String?

    var body: some View {
        Section {
            if config.rules.isEmpty {
                Text(L("No rules. A rule says what happens with waiting commits, e.g. docs go out by themselves once CI is green.",
                       "Keine Regeln. Eine Regel sagt, was mit wartenden Commits passiert, z. B. Doku geht von selbst raus, sobald CI grün ist."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($config.rules) { $r in
                DisclosureGroup {
                    TextField(L("Name", "Name"), text: $r.name)
                    TextField(L("Projects (vercel/name, comma-separated; empty = all)", "Projekte (vercel/name, mit Komma; leer = alle)"),
                              text: Binding(get: { r.projects.joined(separator: ", ") }, set: { r.projects = RulesConfig.list($0) }))
                    Toggle(L("CI is green", "CI ist grün"), isOn: $r.ciGreen)
                    TextField(L("Changed files (globs, e.g. docs/**, *.md)", "Geänderte Dateien (Muster, z. B. docs/**, *.md)"),
                              text: Binding(get: { r.paths.joined(separator: ", ") }, set: { r.paths = RulesConfig.list($0) }))
                    Toggle(L("Only these files changed", "Nur diese Dateien geändert"), isOn: $r.onlyPaths).disabled(r.paths.isEmpty)
                    TextField(L("PR labels (e.g. ship)", "PR-Labels (z. B. ship)"),
                              text: Binding(get: { r.labels.joined(separator: ", ") }, set: { r.labels = RulesConfig.list($0) }))
                    Picker(L("Waiting at least", "Wartet mindestens"), selection: $r.minAgeHours) {
                        Text(L("any time", "beliebig")).tag(Int?.none)
                        ForEach([1, 2, 6, 24, 48], id: \.self) { Text("\($0) h").tag(Int?.some($0)) }
                    }
                    Picker(L("Then", "Dann"), selection: $r.then) { ForEach(RulesConfig.Action.allCases) { Text($0.title).tag($0) } }
                    Button(L("Remove this rule", "Diese Regel entfernen"), role: .destructive) { config.rules.removeAll { $0.id == r.id } }
                } label: {
                    Toggle(isOn: $r.enabled) {
                        VStack(alignment: .leading) {
                            Text(r.name.isEmpty ? L("New rule", "Neue Regel") : r.name)
                            Text(RulesConfig.summary(r)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button(L("Add a rule", "Regel hinzufügen")) {
                    config.rules.append(.init(name: L("Docs go out by themselves", "Doku geht von selbst raus"), ciGreen: true,
                                              paths: ["docs/**", "*.md"], onlyPaths: true, then: .notify))
                }
                Spacer()
                Button(L("Revert", "Zurücksetzen")) { config = saved; error = nil }.disabled(config == saved)
                Button(L("Save", "Speichern")) { error = config.save(); if error == nil { saved = config } }
                    .disabled(config == saved || config.problem != nil)
            }
            if let p = config.problem ?? error { ErrorText(p) }
        } header: {
            Text(L("Rules", "Regeln"))
        } footer: {
            Text(L("The deploys script applies these rules; a script that does not know them yet ignores the file. The app never deploys by a rule itself. A rule that deploys still follows the deploy window.",
                   "Das deploys-Skript wendet diese Regeln an; ein Skript, das sie noch nicht kennt, lässt die Datei liegen. Die App deployt nie selbst nach einer Regel. Eine Regel, die deployt, hält sich weiter an das Deploy-Fenster."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
