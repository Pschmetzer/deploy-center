// Deploy Center — the most common error texts of the `deploys` script, in German when the app is.
// The script speaks English only; its texts are matched whole, so a changed text simply stays English.

import Foundation

enum CLIText {
    /// (pattern, German with $1, $2 … for the captured parts). Anchored, case kept.
    private static let table: [(String, String)] = [
        (#"No project or service named "(.+)" was seen yet \(deploys changed reads the names\)"#,
         #"Noch kein Projekt oder Dienst namens „$1“ gesehen (deploys changed liest die Namen)"#),
        (#"(\S+) not found"#, "$1 nicht gefunden"),
        (#"(\S+) has no known repo"#, "$1 hat kein bekanntes Repo"),
        (#"No deploy of (.+) found"#, "Kein Deploy von $1 gefunden"),
        (#"The newest deploy of (.+) is not live; nothing to check"#, "Der neueste Deploy von $1 ist nicht live; nichts zu prüfen"),
        (#"(.+) is being started already \(wait a minute\)"#, "$1 wird schon gestartet (eine Minute warten)"),
        (#"No deploys now: the deploy window says "(.+)"\. To deploy anyway: --force "why""#,
         #"Gerade keine Deploys: Das Deploy-Fenster sagt „$1“. Trotzdem deployen: --force "Grund""#),
        (#"Could not take the auto-deploy lock; nothing changed"#, "Die Auto-Deploy-Sperre war nicht zu bekommen; nichts geändert"),
        (#"autofix is running already"#, "Autofix läuft schon"),
        (#"Could not reach the Anthropic API\."#, "Die Anthropic-API war nicht erreichbar."),
        (#"This month's Claude cap is reached \((\d+) of (\d+) tokens\)\. Raise it in Settings > Claude in the app, or: deploys ai cap <tokens>"#,
         "Das Claude-Limit dieses Monats ist erreicht ($1 von $2 Tokens). Erhöhen unter Einstellungen > Claude in der App oder: deploys ai cap <tokens>"),
        (#"That does not look like an Anthropic API key \(sk-ant-\.\.\.\)"#, "Das sieht nicht nach einem Anthropic-API-Schlüssel aus (sk-ant-…)"),
        (#"That does not look like a routine token \(sk-ant-\.\.\.\)"#, "Das sieht nicht nach einem Routine-Token aus (sk-ant-…)"),
        (#"Observer mode \((.+?)\): "deploys (.+?)" changes something and is refused\. Observers can look, not deploy\.(.*)"#,
         #"Beobachtermodus ($1): „deploys $2“ ändert etwas und wird abgelehnt. Beobachter können schauen, nicht deployen.$3"#),
        // need_cap: "<Label> cannot <what>" for a platform without that capability.
        (#"(.+) cannot deploy a preview \((.+)\)"#, "$1 kann keine Vorschau deployen ($2)"),
        (#"(.+) cannot read build logs"#, "$1 kann keine Build-Logs lesen"),
        // fetchWarn of a provider (Amplify).
        (#"custom domains could not be read; the address shown may be the default one"#,
         "Eigene Domains waren nicht lesbar; die gezeigte Adresse ist vielleicht die Standardadresse"),
    ]
    private static let compiled: [(NSRegularExpression, String)] = table.compactMap { p, de in
        (try? NSRegularExpression(pattern: "^" + p + "$")).map { ($0, de) }
    }

    /// The German text of a known message (with or without the script's "Error: "), else the message itself.
    static func german(_ message: String) -> String {
        var body = message.trimmingCharacters(in: .whitespacesAndNewlines), prefix = ""
        if body.hasPrefix("Error: ") { body.removeFirst(7); prefix = "Fehler: " }
        let range = NSRange(body.startIndex..., in: body)
        for (re, de) in compiled {
            guard re.firstMatch(in: body, range: range) != nil else { continue }
            return prefix + re.stringByReplacingMatches(in: body, range: range, withTemplate: de)
        }
        return message
    }

    /// What the app shows: German in the German app, the script's own words otherwise.
    /// Line by line: stderr may hold other lines before the error.
    static func shown(_ message: String) -> String {
        guard isGerman else { return message }
        return message.split(separator: "\n", omittingEmptySubsequences: false).map { german(String($0)) }.joined(separator: "\n")
    }
}
