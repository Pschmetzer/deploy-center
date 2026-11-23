// Deploy Center for iPhone — A hint at the likely cause of a failed build, from its error line. Pure logic (no UIKit).
// `topics` is the list of the Mac app's ErrorHelp (app/ErrorHelp.swift); ios/test.sh checks that both lists agree.

import Foundation

enum FailureHint {
    struct Hint: Equatable {
        let en: String, de: String
        /// The section of docs/TROUBLESHOOTING.md that explains it, when there is one.
        let anchor: String?
        func text(german: Bool) -> String { german ? de : en }
    }

    /// A phrase of the message (lowercase) and the anchor of its section in docs/TROUBLESHOOTING.md.
    static let topics: [(needle: String, anchor: String)] = [
        ("install the vercel cli", "connect-vercel--install-the-vercel-cli-then-log-in-once-in-terminal"),
        ("log in once in terminal", "connect-vercel--log-in-once-in-terminal-the-app-uses-that-login"),
        ("several vercel teams", "several-vercel-teams-choose-one-deploys-vercel-team-id"),
        ("ignored build step", "skipped-or-canceled-by-vercel-ignored-build-step"),
        ("github cli is not logged in", "github-cli-is-not-logged-in-so-the-waiting-commits-and-prs-cannot-be-counted-in-terminal-gh-auth-login"),
        ("hourly budget", "githubs-hourly-budget-is-nearly-spent-"),
        ("the render key is wrong", "---http-401-the-render-key-is-wrong-or-expired-deploys-render-set-key"),
        ("rate limit: try again", "---http-429-rate-limit-try-again-in-a-minute"),
        ("deploy window closed", "deploy-window-closed"),
        ("no anthropic api key", "no-anthropic-api-key-run-pbpaste--deploys-ai-set-key-or-set-anthropic_api_key"),
        ("is being started already", "project-is-being-started-already-wait-a-minute"),
    ]

    /// Typical causes in a build log: phrases (lowercase) and the hint. The first matching entry wins, so the narrow ones come first.
    static let causes: [(needles: [String], en: String, de: String)] = [
        (["heap out of memory", "out of memory", "oomkilled", "exit code 137", "exited with 137"],
         "The build ran out of memory. Try a bigger build machine, or fewer tasks at the same time.",
         "Dem Build ging der Speicher aus. Eine größere Build-Maschine oder weniger parallele Aufgaben helfen."),
        (["enospc", "no space left on device"],
         "The build machine ran out of disk space. Clear the build cache and try again.",
         "Auf der Build-Maschine ist kein Platz mehr. Build-Cache leeren und erneut versuchen."),
        (["eresolve", "unable to resolve dependency tree"],
         "Two packages ask for versions that do not fit together. Check the versions in package.json.",
         "Zwei Pakete verlangen Versionen, die nicht zusammenpassen. Versionen in package.json prüfen."),
        (["npm err! code e404", "err_pnpm_fetch_404", "404 not found - get https://registry"],
         "A package was not found in the registry. Check its name and whether it is private.",
         "Ein Paket wurde in der Registry nicht gefunden. Name prüfen und ob es privat ist."),
        (["cannot find module", "module not found", "can't resolve", "err_module_not_found"],
         "A package or file is missing. Check that it is listed in package.json and that the file name matches in upper and lower case.",
         "Ein Paket oder eine Datei fehlt. Prüfen, ob es in package.json steht und ob Groß- und Kleinschreibung des Dateinamens stimmt."),
        (["environment variable", "env var", "is not defined", "missing required env"],
         "A setting (environment variable) seems to be missing for the build. Check the project's settings on the platform.",
         "Für den Build fehlt wohl eine Einstellung (Umgebungsvariable). Die Projekteinstellungen bei der Plattform prüfen."),
        (["command not found", "exit code 127", "exited with 127"],
         "A command in the build is not installed on the build machine. Check the build command.",
         "Ein Befehl im Build ist auf der Build-Maschine nicht installiert. Build-Befehl prüfen."),
        (["permission denied", "eacces"],
         "A file or folder could not be used (permission). Check file modes and the build command.",
         "Eine Datei oder ein Ordner ließ sich nicht verwenden (Berechtigung). Dateirechte und Build-Befehl prüfen."),
        (["type error", "error ts", "typescript error"],
         "The code has a type error. It fails on the platform because the build checks types; fix it, or run the build on your machine first.",
         "Im Code steckt ein Typfehler. Der Build prüft Typen und scheitert deshalb; beheben oder den Build erst auf dem eigenen Rechner laufen lassen."),
        (["etimedout", "timed out", "build timeout", "exceeded the maximum"],
         "Something took too long (the build or a download). Try again; if it repeats, look for the slow step.",
         "Etwas dauerte zu lange (der Build oder ein Download). Erneut versuchen; wiederholt es sich, den langsamen Schritt suchen."),
    ]

    static let base = "https://github.com/Pschmetzer/deploy-center/blob/main/docs/"

    /// The hint for one text (an error line or a message): a documented topic first, then a typical cause. nil when nothing matches.
    static func hint(for text: String) -> Hint? {
        let m = text.lowercased()
        guard !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let t = topics.first(where: { m.contains($0.needle) }) {
            return Hint(en: "This is explained in the troubleshooting guide.", de: "Das ist in der Fehlerhilfe erklärt.", anchor: t.anchor)
        }
        if let cause = causes.first(where: { c in c.needles.contains(where: { n in m.contains(n) }) }) {
            return Hint(en: cause.en, de: cause.de, anchor: nil)
        }
        return nil
    }

    /// The hint for a build log: the error line first, then the lines in order (the excerpt starts shortly before the first error).
    static func hint(lines: [String], errorAt: Int?) -> Hint? {
        if let i = errorAt, lines.indices.contains(i), let h = hint(for: lines[i]) { return h }
        for l in lines { if let h = hint(for: l) { return h } }
        return nil
    }

    /// The troubleshooting page, at the hint's section when it has one.
    static func url(for hint: Hint, german: Bool) -> URL? {
        guard let a = hint.anchor else { return nil }
        return URL(string: base + (german ? "TROUBLESHOOTING.de.md" : "TROUBLESHOOTING.md") + "#" + a)
    }
}
