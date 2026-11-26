# Sicherheitsmodell: was Deploy Center liest, speichert und sendet

Die deutsche Fassung von [SECURITY-MODEL.md](SECURITY-MODEL.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Deploy Center ist eine Mac-App und ein Bash-Skript, die als du laufen, mit deinen eigenen Logins. Es gibt keinen Server, kein Konto und keine Telemetrie. Diese Seite ist die Kurzfassung; [SECURITY.md](../SECURITY.md) im Hauptverzeichnis hat das ganze Bedrohungsmodell, jeden Host, mit dem es spricht, und wie man ein Problem meldet.

## Was es liest

- **Deine Hosts**: Projekt- und Service-Listen, Deploys, Build-Logs und die Auto-Deploy-Einstellung von Vercel, Render und den Hosts zum Zuschalten ([providers/README.md](providers/README.md)), über den Login der `vercel`-CLI oder einen API-Key, den du angegeben hast.
- **Deine Git-Hosts**: Commits, Vergleiche, Pull Requests, Check-Runs und Workflow-Dateinamen von GitHub (Login der `gh`-CLI) und für Repos dort von GitLab ([GITLAB.md](GITLAB.md)). Quellcode auf deiner Platte liest es nicht; für einen Bug-Scan oder Sicherheitscheck startet es Werkzeuge auf einem Klon, den du gewählt hast ([SCAN.md](SCAN.md)).
- **Deine eigenen Seiten**: ihre Icons und ein einfaches GET nach einem Deploy, wenn du `deploys verify` nutzt.
- **Die Konfiguration auf deinem Mac**: `~/.config/deploys` (siehe unten) und die CLI-Logins, die schon da sind.

Alles, was von außen kommt (Projektnamen, Commit-Nachrichten, Build-Logs, eine `deploy-center.json` in einem Repo), gilt als Daten, nie als Code: Es geht als Argument an `jq`, erst nach einer Namensprüfung in API-Pfade und beim MCP-Server als einfache Argumentliste.

## Was es speichert

| Was | Wo | Hinweis |
|---|---|---|
| Der Render-Key, das Claude-Routine-Token, dein Anthropic-Key, die Keys der zuschaltbaren Hosts (u. a. Fly.io, Railway, Heroku, Firebase Hosting, GitHub Pages, Koyeb, Northflank, Deno Deploy), Deploy-Hook-URLs | der macOS-Schlüsselbund, Einträge `deploy-center-…` | Beim Setzen von stdin gelesen, an `curl` über stdin weitergegeben. Nie ein Kommandozeilenargument, nie ausgegeben. In CI kommen sie aus Umgebungsvariablen. |
| Aus welchem Repo und Branch ein Vercel-Projekt deployt hat, die Ignorierliste, Einstellungen, Sperren | `~/.config/deploys` (Modus `0700`) | Keine API-Keys darin. Behalte `vercel-repos.json`, bis Git wieder verbunden ist ([AUTO-DEPLOY.de.md](AUTO-DEPLOY.de.md)). |
| Was App und CLI gestartet, zurückgerollt oder abgebrochen haben | das Deploy-Journal, eine Zeile je Eintrag, per Hash verkettet | Verlässt den Mac nie; Fehlertexte sind maskiert ([JOURNAL.de.md](JOURNAL.de.md)). |
| App-Einstellungen | die Einstellungen der App | [SETTINGS.de.md](SETTINGS.de.md) |
| Keys für die iPhone-App | ein Eintrag im iCloud-Schlüsselbund oder ein QR-Code | Nur wenn du es einschaltest. Der QR-Code ist nicht verschlüsselt: Wer ihn fotografiert, hat die Keys. Nimm Keys nur für das Telefon ([SECURITY.md](../SECURITY.md#iphone-link)). |

`deploys where` zeigt, woher die Keys kommen; `deploys creds` zeigt, ob jeder funktioniert und wie alt er ist. Keiner von beiden gibt einen Key aus.

## Was es sendet, und wohin

| An | Was | Wann |
|---|---|---|
| Vercel, Render und die Hosts, die du zugeschaltet hast | die Aufrufe, die du auch im Dashboard machen würdest: Listen, Deploys, Logs, Starts und Rollbacks | immer, mit deinem Login; Starts nur per Klick oder `--yes` |
| GitHub, GitLab | die Aufrufe für Commits, Pull Requests und Checks | mit deinem `gh`- oder `glab`-Login oder Token |
| deine eigenen Domains | ein GET für das Icon und die Seitenprüfung | nach einem Deploy mit `verify` und für Icons |
| die Statusseiten von Vercel, Render und GitHub | ein einfaches GET, nichts von dir | die App, um zu sagen, ob ein Host gestört ist |
| `deploycenter.app/appcast.xml` | eine Update-Prüfung, ohne Systemprofil | einmal am Tag, abschaltbar; das Update selbst kommt von GitHub |
| Anthropic | ein maskierter Log-Ausschnitt oder Commit-Titel, nur mit deinem eigenen Key oder deiner Routine | erst nachdem du Claude in der App, Autofix oder einen Scan eingerichtet hast, und nur wenn du fragst ([CLAUDE-IN-APP.md](CLAUDE-IN-APP.md#privacy), [AUTOFIX.md](AUTOFIX.md)) |
| OSV und Semgrep | Paketnamen und -versionen; das Regelwerk wird heruntergeladen | nur für den Sicherheitscheck ([SCAN.md](SCAN.md)) |
| ein Webhook deiner Wahl | Projektnamen und Zahlen | nur wenn du die tägliche Zusammenfassung startest |

Sonst verlässt nichts den Mac. Das Maskieren von Build-Logs (Tokens, Passwörter, Keys) ist eine Hilfe, keine Garantie: Kann ein Build Geheimnisse in ungewöhnlicher Form ausgeben, schalte Autofix nicht ein.

## Was es nie von selbst tut

- Einen Build, einen Rollback oder einen Abbruch starten: nur ein Klick oder ein Befehl mit `--yes`. Ein `deploycenter://`-Link zeigt nur ein Projekt oder öffnet einen Einstellungs-Tab.
- Etwas mergen. Autofix und Scans öffnen Pull Requests; ein Mensch mergt.
- Von einem KI-Agenten aus deployen: Der MCP-Server ist nur lesend, es sei denn, du startest ihn mit `DEPLOYS_MCP_ALLOW_DEPLOY=1`, und selbst dann fragt er dich standardmäßig bei jedem (mit `DEPLOYS_MCP_CONFIRM=client` ist die Freigabe des Clients das einzige Ja) ([integrations/mcp](../integrations/mcp/README.md#safety)).
- Auto-Deploy wieder einschalten: Das kannst nur du, und der [Wächter](GUARD.de.md) schaltet es wieder aus.

## So bleibt es dicht

- Lege Keys nur für diese App an und widerrufe sie, wenn du sie deinstallierst ([UNINSTALL.md](UNINSTALL.md)).
- Schalte den Beobachter-Modus ein (`deploys readonly on`) auf Macs, die nur ansehen sollen ([TEAM.md](TEAM.md)). Er verhindert Ausrutscher; er ist keine Zugriffskontrolle.
- Prüfe einen Download, bevor du ihn öffnest ([integrations/VERIFY.md](../integrations/VERIFY.md)).
- Melde ein Problem über ein privates Security Advisory, nicht über ein öffentliches Issue ([SECURITY.md](../SECURITY.md#report-a-problem)).
