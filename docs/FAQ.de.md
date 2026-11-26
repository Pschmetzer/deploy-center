# FAQ (Deutsch)

Die deutsche Fassung von [FAQ.md](FAQ.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

## Was kostet es?
Nichts. Deploy Center ist kostenlos und Open Source (MIT). Du zahlst deinen Hosts (Vercel, Render und die zuschaltbaren: Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean, Coolify, Fly.io, Railway, Heroku, Firebase Hosting, GitHub Pages, Koyeb, Northflank, Deno Deploy) für die Builds, die du startest, und es werden weniger.
`deploys simulate` schätzt, was Auto-Deploy dich im Monat kostet, `deploys ledger`, was das Abschalten gespart hat: [ERSPARNIS.md](ERSPARNIS.md).

## Deployt es von allein etwas?
Nein. Es deployt, wenn du **Deploy** drückst oder einen `deploys`-Befehl ausführst. Die tägliche Erinnerung in den Einstellungen ist nur eine Mitteilung, und nur wenn etwas wartet. Willst du ein geplantes Deploy, richte es selbst ein: [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example) auf dem Mac oder [examples/](../examples/) für CI.

## Was passiert, wenn ich Auto-Deploy abschalte?
Siehe [AUTO-DEPLOY.md](AUTO-DEPLOY.md) (englisch). Kurz: Vercel verliert die Git-Verbindung (das Repo wird gemerkt), bei Render wird Auto-Deploy auf *Off* gestellt, und ein Push baut nichts.

## Kann ich zurück?
Ja: `deploys vercel autodeploy-on <projekt>` verbindet Git wieder aus dem gemerkten Repo, `deploys render autodeploy-on <service>` stellt Auto-Deploy auf *On Commit* (beide mit `--all`; mit `--dry-run` siehst du vorher, was sich ändern würde). Die Dashboards gehen auch. Siehe [AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy).

## Wo liegt mein Render-Schlüssel?
In deinem macOS-Schlüsselbund, als Eintrag `deploy-center-render`. `deploys` gibt ihn über stdin an `curl`, er steht also nicht in der Prozessliste, und sendet ihn nur an api.render.com. Der Schlüssel gibt vollen Zugriff auf dein Render-Konto.

## Sendet die App Daten irgendwohin?
Keine Telemetrie, kein Konto, kein Server von uns. Sie spricht mit Vercel und Render über deine Anmeldungen, mit GitHub über dein `gh`-Login, mit deinen eigenen Seiten für Logos und die Prüfung nach einem Deploy, mit den öffentlichen Statusseiten von Vercel, Render und GitHub (ein einfaches GET, nichts von dir) und einmal am Tag mit `deploycenter.app/appcast.xml`, um zu sehen, ob eine neue Version da ist; das Update selbst kommt von GitHub (Einstellungen → **Automatisch nach Updates suchen** schaltet die tägliche Prüfung ab). Claude in der App und Autofix sprechen nur mit Anthropic, wenn du sie mit deinem eigenen Schlüssel oder deiner Routine einrichtest. Mehr: [SECURITY.md](../SECURITY.md#what-is-sent-where) (englisch).

## Brauche ich die GitHub-CLI?
Zum Deployen nein. Um zu sehen, was wartet (wartende Commits und PRs, **Alle mit Änderungen anhaken**, `deploys changed` und `deploy-changed`), ja: Das liest GitHub über `gh`.

## GitLab oder Bitbucket?
GitLab ja: Für ein Projekt, dessen Repo auf gitlab.com oder deinem eigenen GitLab liegt, wird das Wartende (Commits, gemergte und offene Merge Requests) über `glab` oder `GITLAB_TOKEN` von GitLab gelesen. Siehe [GITLAB.md](GITLAB.md) (englisch). Bitbucket und andere Hosts noch nicht: Bei diesen Projekten ist der Branch-Stand unbekannt.

## Wie stelle ich die App auf Englisch oder Deutsch?
Einstellungen → Allgemein → **Sprache**: English, Deutsch oder die Sprache des Macs (Standard). Es gilt nach einem Neustart (**Jetzt neu starten** steht gleich dabei); die Widgets folgen. Meldungen der `deploys`-CLI bleiben englisch.

## Wie aktualisiere ich?
Die App prüft einmal am Tag (Einstellungen → Allgemein → **Automatisch nach Updates suchen**) und über **Nach Updates suchen …** im App-Menü. Sparkle zeigt, was neu ist, und installiert, sobald kein Deploy läuft. Mit Homebrew: `brew upgrade --cask --greedy deploy-center`.

## Windows oder Linux?
Die App braucht macOS 15 oder neuer. Das Skript `deploys` ist bash und läuft unter Linux und in WSL (installiere es in der Linux-Distribution): `curl -fsSL https://deploycenter.app/install.sh | sh`. In CI kommt der Schlüssel aus `RENDER_API_KEY` statt aus dem Schlüsselbund. Siehe [examples/](../examples/).

## Ich habe ein Vercel-Projekt getrennt, bevor ich Deploy Center benutzt habe. Es steht „Repo unbekannt“.
Sag ihm, woher das Projekt deployt: `deploys vercel map mein-projekt ich/mein-repo main`.

## Mein Login hat mehrere Vercel-Teams.
`deploys vercel team <id>` wählt eins. Die Fehlermeldung nennt die IDs.

## Ein Monorepo baut bei jedem Deploy jedes Projekt.
Nimm Vercels Ignored Build Step, siehe [GLOSSARY.md](GLOSSARY.md#ignored-build-step) (englisch).

## Ein Build lief, obwohl Auto-Deploy aus ist.
Führe `deploys triggers` aus. Es listet Builds der letzten 24 Stunden, die niemand von hier gestartet hat, GitHub-Workflows, die deployen, und Render-Blueprints mit Auto-Sync.

## Wie werden „wartende Commits“ und „wartende PRs“ gezählt?
Siehe [ZAHLEN.md](ZAHLEN.md).

## Wo sehe ich, was deployt wurde, und kann ich es exportieren?
Das Deploy-Journal auf deinem Mac listet jeden Deploy. `deploys journal export` schreibt es als CSV, `deploys journal report` als Monatsbericht in Markdown. Siehe [JOURNAL.de.md](JOURNAL.de.md).

## Wie finde ich schnell die fehlgeschlagenen Render-Dienste?
Tippe `is:failed host:render` ins Suchfeld und speichere es mit dem Lesezeichen-Knopf. Siehe [SEARCH.de.md](SEARCH.de.md).

## Etwas funktioniert nicht.
Siehe [TROUBLESHOOTING.md](TROUBLESHOOTING.md) (englisch).

## Gibt es Vorschau-Deploys?
Wo der Host sie hat: `deploys deploy <projekt> --preview` (Vercel, Cloudflare Pages, AWS Amplify; siehe [die Host-Tabelle](providers/README.md)). Render, Netlify, DigitalOcean und Coolify haben hier keinen Vorschau-Deploy.

## Kann ich zurückrollen?
Ja, bei jedem Host außer einem reinen Deploy-Hook: der Rollback-Knopf in der App oder `deploys <host> rollback <projekt>`. `deploys verify` rollt von allein zurück, wenn die Seite nach einem Deploy mit 5xx antwortet, außer du gibst `--no-rollback` an. Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md) (englisch).

## Gibt es eine iPhone-App?
Sie ist für den App Store gebaut: was wartet, Deploy und Rollback mit Face ID und Widgets, nur für Vercel und Render. Wie sie funktioniert: [WIDGETS-IOS.md](WIDGETS-IOS.md) (englisch).

## Kann mein Team es nutzen?
Ja, ohne Server: eine gemeinsame `deploy-center.json` je Repo, Beobachter-Modus und eine optionale Zwei-Personen-Regel. Siehe [TEAM.md](TEAM.md) (englisch).

## Brauche ich einen Anthropic-Schlüssel?
Nur für Claude in der App (Fehler erklären, Release-Notes, Ship-Check). Autofix nutzt stattdessen eine Claude-Code-Routine. Siehe [CLAUDE-IN-APP.md](CLAUDE-IN-APP.md) (englisch).

## Wo finde ich die Schritt-für-Schritt-Anleitungen?
Auf der Website: [alle Anleitungen auf Englisch](https://deploycenter.app/guides/), die [deutschen Anleitungen](https://deploycenter.app/de/anleitungen/) (Build-Minuten, Deploy-Warteschlange, automatischer Rollback, Monorepo-Regeln, Deploy-Freeze, Statusseite, täglicher Deploy, Risiko-Prüfung), die [Vergleiche](https://deploycenter.app/de/vergleich/) und der [Blog](https://deploycenter.app/de/blog/).

## Wie sperre ich Deploys am Freitagnachmittag?
`deploys freeze add fri 15:00 --reason "kein Deploy vor dem Wochenende"` schreibt eine Sperrzeit in `window.json`, ohne JSON zu bearbeiten; `deploys freeze` listet die Regeln nummeriert und sagt, ob Deploys gerade gesperrt sind. In einer Sperrzeit starten `deploy`, `deploy-changed --yes` und das Deploy der App nicht. Eine fertige Datei: [examples/config/window-friday-freeze.json](../examples/config/window-friday-freeze.json). Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md#3-deploy-window--freeze) (englisch).

## Kann ich trotzdem in einer Sperrzeit deployen?
Ja, mit einer Begründung: `deploys deploy-changed --yes --force "Hotfix für die Anmeldeseite"`. Jedes so gestartete Projekt bekommt einen `forced`-Eintrag im Journal mit Sperrzeit und Begründung. Vorschauen, Rollbacks und `verify` hält eine Sperrzeit nie auf, denn ein Rollback ist eine Reparatur.

## Zu welchem Tag gehört eine Sperrzeit über Mitternacht, und welche Zeitzone gilt?
Eine Regel wie `"from": "22:00", "to": "06:00"` gehört zu dem Tag, an dem sie beginnt. Es gilt die Uhr dieses Macs, außer `window.json` nennt eine Zone: `{"tz": "Europe/Berlin", "deny": [...]}`. `deploys window` warnt vor Schlüsseln, Zeiten und Tagen, die es nicht versteht ([CLI.de.md](CLI.de.md)).

## Wie führe ich vor oder nach einem Deploy ein Skript aus?
Lege eine ausführbare Datei namens `pre-deploy*` oder `post-deploy*` in `~/.config/deploys/hooks.d`. Sie bekommt `DEPLOYS_PLATFORM`, `DEPLOYS_PROJECT`, `DEPLOYS_SHA` und nach dem Start `DEPLOYS_STATE`. Ein `pre-deploy`-Hook mit Exit-Code ungleich 0 stoppt diesen Start; ein `post-deploy`-Hook kann nichts stoppen. Drei Beispiele stehen in [examples/config/hooks.d/](../examples/config/hooks.d/), die Regeln in [CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd) (englisch).

## Kann ein Repo über `hooks.d` ein Skript auf meinem Mac starten?
Nein. Hooks werden nur aus deinem eigenen Konfigurationsordner gelesen, nie aus einem Repo oder einer gemeinsamen `deploy-center.json`. Eine Hook-Datei, in die die Gruppe oder andere schreiben dürfen oder die einem anderen Konto gehört (root ausgenommen), läuft nicht; die Meldung sagt, was du mit `chmod` ändern musst.

## Was, wenn ein Hook hängt?
Nach `DEPLOYS_HOOK_TIMEOUT` Sekunden (Standard 300; `0` heißt ohne Grenze) wird der Hook gestoppt und gilt als fehlgeschlagen. Bei einem `pre-deploy`-Hook heißt das: Der Start wird abgelehnt. Die Grenze setzt `perl`, `timeout` oder `gtimeout` auf dem Rechner voraus; ohne eines davon läuft ein hängender Hook ohne Limit und kann den Start blockieren.

## Ist `hooks.d` dasselbe wie `deploys hooks install`?
Nein. `deploys hooks install` legt einen Git-`pre-push`-Hook in ein Repo, der zeigt, welche Builds ein Push starten würde. `hooks.d` hat mit Git nichts zu tun: Seine Skripte laufen um ein Deploy herum, das du aus Deploy Center startest.

## Kann ich begrenzen, was Builds im Monat kosten?
Ja, für Vercel: `deploys budget set 50` (Dollar im Monat; auch `--strict`). Das ist eine Prüfung, keine harte Obergrenze: Sie nutzt die Kosten bis gestern plus eine Schätzung, ein Monat kann also trotzdem über der Zahl enden. Bevor `deploy-changed --yes` etwas startet, addiert es die Kosten dieses Monats bis gestern und die Schätzung des Plans; über dem Budget hält es an, außer du gibst `--force "Grund"` an, was ins Journal kommt. Ohne `--strict` warnt es und macht weiter, wenn die Kosten nicht lesbar sind; mit `--strict` hält es an. Render hat keine Abrechnungs-API und zählt nicht mit. [examples/config/budget.json](../examples/config/budget.json) ist die Datei, die es schreibt.

## Wie lasse ich reine Doku-Änderungen von allein live gehen?
Mit einer Regel in `rules.json`: `when` die geänderten Pfade nur `docs/**` sind und CI grün ist, `then` `deploy`, und das tägliche Deploy mit `--by-rules` laufen lassen. Sperrzeit und Budget zählen weiter. `deploys rules check` zeigt jede Regel gegen jedes wartende Projekt und was nicht erfüllt war. Beispiel: [examples/config/rules-docs-ship.json](../examples/config/rules-docs-ship.json). Siehe [CLI.md](CLI.md#rules) (englisch).

## Welche Regel gewinnt, wenn zwei passen, und wie schreibe ich „oder“?
Die erste aktive Regel, die auf ein Projekt passt, entscheidet. Alle Bedingungen innerhalb einer Regel müssen zutreffen (UND). Für „fünf Commits oder drei Tage“ schreibst du zwei Regeln, wie in [examples/config/rules-collect-then-ship.json](../examples/config/rules-collect-then-ship.json). Eine `deploy`-Regel ohne jede Bedingung wird ignoriert, weil sie alles deployen würde.

## Wie nehme ich ein Projekt aus der Liste?
`deploys ignore mein-projekt` lässt es aus `changed` und `deploy-changed` heraus; `deploys ignore mein-projekt --undo` zählt es wieder mit, und `deploys ignore --list` zeigt, was ignoriert wird. Ein Team kann ein Projekt für alle mit `ignored` in `deploy-center.json` ignorieren; ein Mac kann es für sich wieder mitzählen ([TEAM.md](TEAM.md), englisch).

## Woher kommt eine Einstellung, und wo liegt mein Konfigurationsordner?
`deploys config` zeigt jede wirksame Einstellung und woher sie kommt (eine gemeinsame Datei im Repo oder dieser Mac); `--json` gibt dasselbe für Skripte aus. `deploys where` nennt den Konfigurationsordner (`~/.config/deploys` oder `DEPLOYS_CONFIG`), die Version und woher die Schlüssel kommen.

## Kann ein Teammitglied oder ein CI-Job nur ansehen und nicht deployen?
Ja: Beobachter-Modus. Setze `DEPLOYS_READONLY=1`, lege die Datei `~/.config/deploys/readonly` an (`deploys readonly on`) oder trage ein GitHub-Login unter `observers` in `deploy-center.json` ein. Alle Befehle, die nur lesen, laufen weiter; Befehle, die etwas starten, stoppen oder umschalten, lehnen ab, bevor sie etwas aufrufen. `freeze` bleibt erlaubt, da es nur Zeiten sperrt ([TEAM.md](TEAM.md#2-observer-mode), englisch).

## Hält die Zwei-Personen-Regel jemanden mit Vercel-Login auf?
Nein. Der Team-Modus hält ein Team einheitlich, erzwingt aber nichts: Wer ein Vercel- oder Render-Login hat, kann weiter im Dashboard deployen. Erzwingen geht mit den Rollen der Plattformen und dem Branch-Schutz von GitHub. Deploy Center macht den vereinbarten Weg zum einfachen und schreibt jede Ausnahme auf ([TEAM.md](TEAM.md), englisch).

## Mein geplanter GitHub-Workflow hat ohne Fehler aufgehört.
GitHub schaltet einen `schedule:`-Workflow ab, wenn das Repo 60 Tage lang keine Aktivität hatte, und ein privates Repo, das nur das tägliche Deploy enthält, ist genau das. Schau ab und zu in den Actions-Tab und lass den Workflow melden, wenn ein Lauf fehlschlägt ([examples/README.md](../examples/README.md), englisch).
