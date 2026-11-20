# Glossar (Deutsch)

Die deutsche Fassung der neueren Einträge von [GLOSSARY.md](GLOSSARY.md); die älteren Einträge stehen dort nur auf Englisch. Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

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
