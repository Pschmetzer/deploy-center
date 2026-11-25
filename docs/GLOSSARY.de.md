# Glossar (Deutsch)

Die deutsche Fassung von [GLOSSARY.md](GLOSSARY.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

## Auto-Deploy
Die Plattform baut und deployt bei jedem Push ins Repo. Deploy Center schaltet das ab, damit nur gebaut wird, wenn du es startest.

## Deploy-Fenster
Eine Regel, die sagt, wann Deploys gesperrt sind (zum Beispiel Freitagnachmittag). `deploys window` zeigt, ob es offen ist, und endet mit 1, solange es gesperrt ist; `--force "Grund"` geht durch, und der Grund kommt ins Journal. Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md).

## Sperrzeit (Freeze)
Eine gesperrte Zeit im Deploy-Fenster, etwa Freitag ab 15:00 oder die Tage um einen Feiertag. `deploys freeze add fri 15:00 --reason "…"` schreibt sie in `window.json`; `deploys freeze` listet die Sperrzeiten. Siehe [SAFE-DEPLOY.md](SAFE-DEPLOY.md) und [examples/config/](../examples/config/).

## Erzwungener Start
Ein Start in einer Sperrzeit oder über dem Budget, mit `--force "Grund"` bewusst gemacht. Der Grund und die Sperrzeit oder das Budget, das überschritten wurde, stehen als `forced`-Eintrag im Journal.

## Hook (`hooks.d`)
Eine ausführbare Datei namens `pre-deploy*` oder `post-deploy*` im Ordner `hooks.d` der Konfiguration. Sie läuft um `deploys deploy <Projekt>`, um `deploy-changed` und um den geplanten Job; die Form mit vorangestelltem Anbieter (`deploys vercel deploy <Name>`) führt keine Hooks aus. Ein `pre-deploy`-Hook mit Exit-Code ungleich 0 stoppt diesen Start; ein `post-deploy`-Hook kann das nicht. Nicht der Git-`pre-push`-Hook von `deploys hooks install`. Siehe [CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd) (englisch).

## Budget-Bremse
`budget.json` (`deploys budget set 50`): die Dollar im Monat an Vercel-Build-Kosten, die `deploy-changed --yes` ohne `--force "Grund"` nicht überschreiten darf. Mit `strict` hält es auch an, wenn die Kosten nicht lesbar sind.

## Regel (`rules.json`)
Eine „wenn … dann …“-Zeile für das tägliche Deploy: `when` nennt Bedingungen (Projekte, geänderte Pfade, CI grün, Labels, Alter, Zahl der Commits oder PRs), `then` ist `deploy`, `hold` oder `notify`. Die erste aktive Regel, die auf ein Projekt passt, entscheidet. `deploys rules check` zeigt, warum eine Regel passte oder nicht. Siehe [CLI.md](CLI.md#rules) (englisch).

## Konfigurationsordner
Wo Deploy Center seine Dateien auf einem Mac oder in CI ablegt: `~/.config/deploys` oder der Ordner, den `DEPLOYS_CONFIG` nennt. Hier liegen `window.json`, `rules.json`, `budget.json`, `ignored.json` und `hooks.d`. `deploys where` gibt ihn aus.

## Gemeinsame Konfiguration (`deploy-center.json`)
Eine Datei im Wurzelordner eines Repos (oder `.deploy-center.json`), die jedem Mac im Team dieselben Projekte, Gruppen, Fenster und Freigaben gibt, ohne Server. Die eigenen Dateien dieses Macs werden obendrauf gelegt. Siehe [TEAM.md](TEAM.md) (englisch).

## Deploy-Gruppe
Projekte, die zusammen und der Reihe nach deployt werden: `deploys deploy <Gruppe>` startet jedes, sobald das davor live ist (Backend vor Frontend). Sie steht unter `groups` in `deploy-center.json`; mit `checks` laufen die Gesundheitsprüfungen jedes Mitglieds, mit `stopOnFail` hält ein Fehler den Rest an.

## Beobachter-Modus
Ein Modus, in dem `deploys` nur liest: Befehle, die etwas ändern, werden abgelehnt. Er wird mit `deploys readonly on`, `DEPLOYS_READONLY` oder einer Beobachterliste in der gemeinsamen `deploy-center.json` eingeschaltet. Siehe [TEAM.md](TEAM.md) (englisch).

## Zwei-Personen-Regel
Eine optionale Team-Regel: Ein Live-Deploy braucht die Freigabe einer anderen Person, gespeichert in der gemeinsamen `deploy-center.json` des Repos, ohne Server. Siehe [TEAM.md](TEAM.md) (englisch).

## Git-Verbindung (Vercel)
Die Verbindung zwischen einem Vercel-Projekt und seinem GitHub-Repo. Sie sorgt dafür, dass Vercel bei jedem Push baut. Deploy Center entfernt sie, um Auto-Deploy auszuschalten, und merkt sich vorher Repo und Branch in `~/.config/deploys/vercel-repos.json`.

## Auto-Deploy-Einstellung (Render)
Eine Einstellung pro Service bei Render: *On Commit*, *After CI Checks Pass* oder *Off*. Deploy Center setzt sie auf *Off* (`autoDeployTrigger: off` in der API und in `render.yaml`).

## Produktions-Branch
Der Branch, dessen neuester Commit live geht, meist `main`. Bei Vercel steht er als `ref` in `vercel-repos.json`, bei Render ist es der Branch des Services.

## Preview-Deployment
Ein Vercel-Deployment mit eigener URL, das die Produktion nicht ersetzt. `deploys vercel deploy my-project --preview` oder **Preview** im Rechtsklick-Menü der App.

## Rollback
Die Produktion geht auf den Deploy zurück, der vor dem aktuellen live war. Deploy Center überspringt einen älteren Deploy desselben Commits, damit ein Rollback wirklich ändert, was live ist.

## Ignored Build Step
Eine Vercel-Projekteinstellung (Settings → Git → Ignored Build Step) mit einem Befehl, der entscheidet, ob gebaut wird. Endet er mit 0, überspringt Vercel den Build. In einem Monorepo überspringt `git diff --quiet HEAD^ HEAD -- .` den Build, wenn sich im Ordner des Projekts nichts geändert hat. Die App meldet dann „Skipped or canceled by Vercel (Ignored Build Step?)“.

## Blueprint
Renders Infrastruktur als Code: Services, beschrieben in einer `render.yaml` im Repo. Mit **Auto-Sync** wendet Render die Datei bei einem Push erneut an, was Auto-Deploy wieder einschalten kann. Trage `autoDeployTrigger: off` bei jedem Service in der Datei ein.

## Deploy-Hook (Plattform)
Eine geheime URL, die einen Deploy startet, wenn etwas sie aufruft, zum Beispiel ein GitHub-Workflow. Sie funktioniert ohne Auto-Deploy und kann also weiterbauen, wenn Auto-Deploy aus ist. `deploys triggers` sucht Workflows, die eine aufrufen.

## Stop builds (Netlify)
Netlifys `build_settings.stop_builds`. Es stoppt Builds bei einem Push, aber auch über die API und über Build-Hooks, deshalb nutzt Deploy Center es nicht. Es schaltet Pushes mit einem Ignore-Befehl in `netlify.toml` ab und deployt über einen Build-Hook: [providers/netlify.md](providers/netlify.md) (englisch).

## Branch-Steuerung (Cloudflare Pages)
Die Git-Schalter des Projekts für **Produktions-** und **Preview-Deployments**. `deploys cloudflare off` schaltet beide aus und merkt sich den alten Stand: [providers/cloudflare.md](providers/cloudflare.md) (englisch).

## Auto-Build (AWS Amplify)
Mit Auto-Build baut Amplify jeden verbundenen Branch bei jedem Push. Deploy Center schaltet es pro Branch aus und startet beim Deployen einen Job: [providers/amplify.md](providers/amplify.md) (englisch).

## Deploy on push (DigitalOcean), Auto-Deploy (Coolify)
Das `deploy_on_push` je Komponente bei DigitalOcean App Platform und das `is_auto_deploy_enabled` einer Anwendung bei Coolify. `autodeploy-off` setzt beides auf false: [providers/digitalocean.md](providers/digitalocean.md), [providers/coolify.md](providers/coolify.md) (englisch).

## Merge Request (GitLab)
GitLabs Name für einen Pull Request. Bei einem Repo auf GitLab zählt „PRs waiting“ Merge Requests: [GITLAB.md](GITLAB.md).

## Build-Minuten
Was Vercel und Render fürs Bauen berechnen. Jeder Push mit eingeschaltetem Auto-Deploy kostet einen Build pro verbundenem Projekt.

## Live-Commit
Der Commit des Deploys, der jetzt live ist.

## Branch-Spitze
Der neueste Commit des Produktions-Branches auf GitHub, gelesen mit der GitHub-CLI (`gh`).

## Geändert / Neue Änderungen
Ein Projekt, dessen Live-Commit nicht die Branch-Spitze ist. Die genaue Regel steht in [NUMBERS.md](NUMBERS.md) (englisch).

## Wartende Commits, wartende PRs
Wie viele Commits und gemergte Pull Requests auf dem Branch liegen, aber nicht live sind. Siehe [NUMBERS.md](NUMBERS.md) (englisch).

## Täglicher Deploy
Alles mit Änderungen einmal am Tag deployen: **Alle geänderten wählen** und **Deploy** in der App oder `deploys deploy-changed --yes`.

## Startsperre
Ein zweiter Start desselben Projekts innerhalb einer Minute wird abgelehnt, in der App wie in der CLI, damit zwei schnelle Klicks nicht zwei Builds kosten.

## Ignoriertes Projekt
Ein Projekt, das bei `changed` und `deploy-changed` fehlt: `deploys ignore my-project`, rückgängig mit `deploys ignore my-project --undo`.

## Ausgeblendetes Projekt
Eine in der App ausgeblendete Zeile. Ausgeblendete Projekte stehen in Einstellungen → Allgemein, wo **Anzeigen** sie zurückbringt.

## Repo-Gruppe
Projekte, die ein GitHub-Repo teilen, unter einer Kopfzeile in der Liste. Die Kopfzeile klappt zu (der Zustand wird gemerkt) und zählt fehlgeschlagene Projekte. Siehe [SEARCH.md](SEARCH.md#repo-groups) (englisch).

## Gespeicherte Suche
Eine Suche wie `is:failed host:render`, die du mit dem Lesezeichen-Knopf neben dem Suchfeld behältst. Sie ist nur Text auf diesem Mac; sie auszuführen ändert nichts. Siehe [SEARCH.md](SEARCH.md#saved-searches) (englisch).

## Gemergter Fix
Ein [Autofix](AUTOFIX.md)-Pull-Request, der gemergt, aber noch nicht live ist. Seine Zeile fällt auf, und **Mehr → Die N gemergten Fixes ankreuzen** kreuzt alle an. Das Deployen braucht weiterhin einen Klick.

## Demo-Modus
Einstellungen → Allgemein → Demo-Modus ersetzt Projektnamen und Domains, für Screenshots.

## GitHub-Budget
GitHubs Stundenlimit an API-Aufrufen für deinen Login. Bei weniger als 300 übrig liest Deploy Center nur die Branch-Spitzen. `deploys github-budget` zeigt, was noch übrig ist.

## Verify (Gesundheitsprüfung)
`deploys verify <project>` fragt nach einem Deploy die Live-Seite ab und macht bei einer 5xx-Antwort einen Rollback, außer du gibst `--no-rollback` an.

## Autofix-Routine
Eine Claude-Code-Routine, die du einmal einrichtest. Schlägt ein Build fehl, schickt `deploys autofix` ihr das maskierte Build-Log, und die Routine öffnet einen Fix-Pull-Request. Sie mergt nie und deployt nie. Siehe [AUTOFIX.md](AUTOFIX.md).

## Guard
`deploys guard` bemerkt, wenn Auto-Deploy von selbst wieder an ist, und schaltet es erneut aus; es kann Auto-Deploy auch absichtlich für ein paar Stunden erlauben. Siehe [GUARD.md](GUARD.md).

## MCP-Server
Der `deploys`-Server, mit dem ein KI-Agent in Claude Code, Cursor oder Codex liest, was wartet, und nach deiner Bestätigung deployt. Siehe [integrations/mcp](../integrations/mcp/).

## Simulate und Ledger
`deploys simulate` schätzt, was Auto-Deploy einen Monat gekostet hätte, bevor du es abschaltest; `deploys ledger` schätzt, was das Abschalten gespart hat. Beides ist als Schätzung gekennzeichnet. Siehe [SAVINGS.md](SAVINGS.md) (englisch).
