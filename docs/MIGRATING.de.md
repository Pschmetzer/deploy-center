# Von Auto-Deploy auf Deploys per Hand umsteigen

Die deutsche Fassung von [MIGRATING.md](MIGRATING.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Eine Checkliste für alle, bei denen heute „jeder Push deployt" gilt und die künftig „ein Deploy am Tag, mit Absicht" wollen. Für ein paar Projekte reicht ein Nachmittag. [SAFE-START.de.md](SAFE-START.de.md) ist die kurze Tour, diese Seite der Plan drumherum. Nichts davon startet einen Build, solange kein Befehl `--yes` hat und du nicht klickst.

## 1. Herausfinden, was heute baut

```bash
deploys doctor --text            # Werkzeuge und Logins, mit der Lösung zu jedem Problem
deploys list                     # jedes Projekt, und ob ein Push es noch deployt
deploys triggers                 # Builds, die niemand von hier gestartet hat, Workflows, Blueprints
deploys simulate --days 30       # eine Schätzung: ein Monat Auto-Deploy gegen ein Deploy am Tag
```

`deploys triggers` überrascht am meisten. Das baut weiter, auch wenn Auto-Deploy aus ist, weil es die Git-Verbindung nicht braucht:

- ein GitHub-Actions-Workflow, der deployt (`vercel deploy`, ein Deploy-Hook per `curl`, `render deploy`),
- ein Deploy-Hook, den jemand in einen Webhook eingetragen hat (ein CMS, ein Cron-Dienst),
- ein Render-Blueprint mit Auto-Sync (`autoDeployTrigger: off` bei jedem Service in `render.yaml`),
- Vorschau-Builds für Pull Requests: bei Vercel enden sie mit der Git-Verbindung; prüfe, ob deine Render-Services eigene Vorschauen haben.

Entscheide für jeden: behalten, hinter einen Klick legen oder löschen.

## 2. Die Regel festlegen

Schreibt auf, was „ein Deploy" heißt, bevor jemand etwas ausschaltet:

- **Wann**: eine feste Uhrzeit am Tag (`deploys schedule daily 17:30 --weekdays`), oder per Hand, wenn ein Fix live muss. [SAFE-DEPLOY.md](SAFE-DEPLOY.md) behandelt Deploy-Fenster und Freezes.
- **Was**: nur Commits mit grüner CI (`--when-green`), und welche Projekte nie gebündelt werden (`hold`-Regeln, [CLI.md](CLI.md#rules)).
- **Wer**: Im Team-Modus bringt eine gemeinsame `deploy-center.json` dieselben Regeln auf jeden Mac; Beobachter dürfen nur ansehen ([TEAM.md](TEAM.md)).

## 3. Ausschalten, zuerst ein Projekt

Folge [SAFE-START.de.md](SAFE-START.de.md): ein Projekt, das ein paar Minuten veraltet sein darf, eine Vorschau, dann Produktion, dann einen Commit pushen und prüfen, dass kein Build startet. Erst dann `--all`. Alles wird festgehalten, damit es sich rückgängig machen lässt: Bei Vercel landen Repo und Branch zuerst in `~/.config/deploys/vercel-repos.json` ([AUTO-DEPLOY.de.md](AUTO-DEPLOY.de.md)).

## 4. Das tägliche Deploy einrichten

```bash
deploys deploy-changed                       # zeigt, was es deployen würde
deploys deploy-changed --when-green --yes    # nur grüne Commits (wartet auf laufende Checks)
deploys schedule daily 17:30 --weekdays --when-green
```

`deploys plan` zeigt dieselbe Liste mit einer Kostenschätzung. In der App: die geänderten Projekte auswählen, die Commit-Nachrichten in der Bestätigung prüfen, **Deploy** drücken.

## 5. Sicherheitsnetze einschalten

- `deploys deploy my-project && deploys verify my-project --path /health` fragt die Seite nach einem Deploy und rollt zurück, wenn sie mit 5xx antwortet ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)).
- `deploys guard schedule on` schaltet Auto-Deploy binnen 30 Minuten wieder aus, wenn jemand es einschaltet ([GUARD.de.md](GUARD.de.md)). Für ein paar Stunden Auto-Deploy mit Absicht: `deploys autodeploy allow vercel my-project 4`.
- `deploys journal verify` prüft das Journal darüber, was gestartet wurde ([JOURNAL.de.md](JOURNAL.de.md)).

## 6. Nach einer Woche

`deploys ledger` zeigt eine Schätzung der übersprungenen Builds und des gesparten Geldes seit dem Ausschalten ([ERSPARNIS.md](ERSPARNIS.md)). Muss ein Projekt schneller als einmal am Tag live, deploye es per Hand (`deploys deploy my-project`) oder erlaube ihm Auto-Deploy; du musst nicht ganz zurück.

## Zurück

```bash
deploys vercel autodeploy-on --all     # verbindet Git wieder aus den gemerkten Repos
deploys render autodeploy-on --all     # Auto-Deploy „On Commit"
```

Behalte `~/.config/deploys/vercel-repos.json`, bis jedes Vercel-Projekt wieder verbunden ist. Was die anderen Hosts können: [providers/README.md](providers/README.md).
