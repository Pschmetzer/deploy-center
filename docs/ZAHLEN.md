# Wie die App zählt

- **Hat Änderungen** (`CHANGED_RULE` in `deploys`): deploybar, nicht pausiert, nicht im Bau, Kopf bekannt, und der Live-Commit unterscheidet sich vom Kopf des Branches (ohne Commit-Kennung: Zeitvergleich).
- **Commits warten**: `ahead_by` aus dem GitHub-Vergleich Live-Commit … Branch (exakt).
- **PRs warten**: PR-Nummern in den Commit-Nachrichten (`(#12)`, `Merge pull request #12`); Rebase-Merges ohne Nummer werden über `commits/{sha}/pulls` nachgefragt (höchstens 10). Mehr als 250 Commits: untere Grenze („mindestens“).
- **Gleiches Repo, mehrere Projekte** (Frontend + Backend): im Banner und in der Menüleiste einmal gezählt; in der Liste stehen die Zeilen zusammen, die späteren sagen „wie oben“.
- **Offene PRs**: pro Repo, Entwürfe und Bots getrennt ausgewiesen.
- **Force-Push**: ist der Live-Commit nicht mehr im Repo, steht „Branch wurde umgeschrieben“ statt einer Zahl.
- **Nach einem Rollback**: der Stand ist älter als der Branch, die Zeile hat wieder Änderungen.
- **GitHub-Limit**: unter 300 verbleibenden Aufrufen werden nur noch die Köpfe gelesen (kein Vergleich, keine offenen PRs).
