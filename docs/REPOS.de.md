# Repo-Pflege

Wenn Claude-Code-Sessions in Worktrees oder in der Cloud arbeiten und über Pull Requests mergen, bleibt der
Haupt-Checkout eines Projekts auf dem Branch stehen, auf dem er zuletzt war. Ein paar Tage später liegt er Hunderte
Commits hinter `origin/main`, alte Branches sammeln sich, ebenso Worktrees, die niemand mehr nutzt. `deploys repos`
zieht diese Checkouts wieder auf den Stand von origin, und zwar nur dort, wo dabei nichts verloren gehen kann.

English: [REPOS.md](REPOS.md)

## Im Terminal

```bash
deploys repos status            # fetch, dann Stand je Checkout und was ein sync täte; nichts ändert sich
deploys repos sync --yes        # ausführen (ohne --yes: derselbe Bericht wie status)
deploys repos last --json       # das letzte Ergebnis, ohne git und Netz (App und MCP-Server lesen es)
deploys repos schedule on       # alle 30 Minuten und beim Anmelden, mit niedriger Priorität (LaunchAgent)
deploys repos schedule off
```

## Was mit einem Checkout passiert

Nach `git fetch origin` (alte Remote-Branches werden erst gelöscht, wenn `sync` entschieden hat; so bleibt ein auf origin gelöschter Branch als vollständig gepusht erkennbar):

| Der Checkout | Was passiert |
| --- | --- |
| keine Änderungen, auf `main` und zurück | `git merge --ff-only origin/main` (nie ein Merge-Commit) |
| keine Änderungen, auf einem gemergten Branch | zurück auf `main`, fast-forward, der Branch wird gelöscht |
| keine Änderungen, Branch auf origin gelöscht, jeder Commit war gepusht | zurück auf `main`, fast-forward; der Branch bleibt |
| keine Änderungen, Branch mit eigenen Commits | wird gemeldet (wie weit vor und zurück); nichts ändert sich |
| ungespeicherte Änderungen, neue Dateien, ein Konflikt, ein laufender Merge, Rebase oder Cherry-Pick | **nie angefasst**, steht unter „Braucht dich“ |
| lokaler `main` mit Commits, die nicht auf origin sind | es wird nicht dorthin gewechselt, steht unter „Braucht dich“ |

Ein Branch gilt als gemergt, wenn seine Commits in `origin/main` sind, wenn ein Merge dorthin nichts ändern würde
(Squash-Merge) oder wenn `gh` einen gemergten Pull Request zeigt, dessen Kopf genau dieser Commit ist. Der Commit des
gelöschten Branches steht im Ergebnis und im Journal: `git branch <name> <commit>` holt ihn zurück.

Ein Checkout bleibt außerdem unberührt, wenn der Fetch scheiterte, wenn er in der letzten Stunde benutzt wurde (der
Wechsel wartet auf den nächsten Lauf) und wenn die Aktualisierung eine ignorierte Datei wie eine lokale `.env`
überschreiben würde, die der neue Commit enthält. Git-Hooks sind dabei aus, ein Hintergrundlauf startet also nie
`npm install`.

Verknüpfte Worktrees: `git worktree prune`, dann wird ein Worktree ohne Änderungen, einen Tag unbenutzt, ohne Prozess
darin und mit gemergtem Branch per `git worktree remove` (ohne `--force`) entfernt und sein Branch gelöscht. Worktrees
unter `.claude/worktrees` überlässt es der Claude-App. Den Speicher alter Worktrees gibt `deploys clean` frei.

## Welche Repos

`repos.json` im Konfigurationsordner (optional):

```json
{"roots": ["~/Code"], "repos": ["~/anderes/projekt"], "skip": ["ein-repo"]}
```

Ohne sie die `roots` aus `clean.json`, ohne die `~/Documents/Claude`. Ein Repo ist ein Ordner direkt unter einer
Wurzel mit einem `.git`-Ordner; ein verknüpfter Worktree gehört zu seinem Haupt-Checkout.

## In der App und für Claude

Deploy-Menü → **Repo-Pflege …**: jeder Checkout mit Branch und Rückstand, die, die dich brauchen, oben, ein Knopf
**Jetzt pflegen** und der Schalter für den Zeitplan. Das MCP-Werkzeug `deploys_repos` liefert das letzte Ergebnis (nur
lesend); `refresh: true` lässt vorher `deploys repos status` laufen.

## Liegengebliebene Arbeit retten

`deploys repos stranded` listet Ordner (auch `.claude/worktrees`) mit nicht committeten Änderungen oder Commits, die
auf keinem Remote sind, zuerst die aus archivierten Sitzungen. `deploys repos rescue <ordner> --yes` schiebt sie auf
einen neuen Branch `rescue/<ordner>-<zeit>` und öffnet eine Entwurfs-PR; der Ordner selbst bleibt unverändert.
Abgelehnt wird bei Geheimnissen (`.env`, Schlüssel, Tokens), Dateien über 5 MB, mehr als 300 Dateien oder einem
verschachtelten Repo. In der Menüleiste: „Liegengebliebene Arbeit“, ein Klick fragt vorher.
