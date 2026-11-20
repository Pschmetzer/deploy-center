# FAQ (Deutsch)

Die deutsche Fassung von [FAQ.md](FAQ.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

## Was kostet es?
Nichts. Deploy Center ist kostenlos und Open Source (MIT). Du zahlst deinen Hosts (Vercel, Render und die zuschaltbaren: Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean, Coolify) für die Builds, die du startest, und es werden weniger.
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
Auf der Website: [alle Anleitungen auf Englisch](https://deploycenter.app/guides/), die [deutschen Anleitungen](https://deploycenter.app/de/guides/) (Build-Minuten, Deploy-Warteschlange, automatischer Rollback, Monorepo-Regeln, Deploy-Freeze, Statusseite, täglicher Deploy, Risiko-Prüfung), die [Vergleiche](https://deploycenter.app/de/vergleich/) und der [Blog](https://deploycenter.app/de/blog/).
