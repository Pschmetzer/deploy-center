# Runde 7: Website, Doku, Community (Stand)

Nummern aus dem Website/Doku/Tests-Audit. Branch `feat/site-docs-round-7`.

## Umgesetzt

- **Fehler und Widersprüche:** 1, 2 (JSON-LD, llms.txt, `check-release.py` prüft beides), 52, 53 (eine Env-Tabelle, eine Exit-Code-Zeile), 55 (doppelte Zeilen in `docs/README.md`), 56 (Good-first-issues), 57, 58 (perl optional in `install.sh`), 59, 60 (Statusseiten in README und FAQ), 70, 71, 72 (`build-docs.py`), 73.
- **install.sh:** 37 (Zeitlimits), 38 (Archivpfade), 39 (Versionsabgleich), 40 (genau eine Prüfsummenzeile), 43 (`--sha256`), 45 (`--dry-run`, `--quiet`), 138 (sudo-Zusammenfassung).
- **Web und A11y:** 24, 25, 26, 27, 29, 33, 34, 18, 19, 134.
- **SEO:** 3, 4 (Längenwarnungen in `check-site.py`), 6 bis 10 (fünf neue Guides), 15, 16, 17, 20 (nur `softwareHelp`), 22 (Glossar), 23 (FAQ-Anker), 128, 129, 131.
- **Doku:** 61 (teilweise: Host-Abschnitte, abgelehnte Deploys), 62, 63 und 64 (Host-Matrix `docs/providers/README.md`), 66 (`AGENTS.md`), 69 (README-Parität in `scripts/check-docs.py`), 95 (jede Doku-Seite einmal in `docs/README.md`), 107 (`.gitignore`), 108 (`CITATION.cff`), 139, 141, 142, 143, 75.

## Nicht umgesetzt

- **Fremdrevier (andere Forks):** Tests 76 bis 94, 146 bis 150, CI, Issue-Templates, Release-Skripte (41, 42), Beispiel-Workflows (49 bis 51), Docker-Texte (46 bis 48, 144), `integrations/README.md` (Tippfehler dort), Statusseite und Badge.
- **Wegen Abhängigkeit:** 65 (`docs/CLAUDE.md` umbenennen: Kommentare in `deploys` und `examples/` verweisen darauf).
- **Offen, weil größer oder nicht belegbar:** 5 (Primärquellen-Links), 11 bis 14 (weitere Guides, Vercel/Render-Providerseiten), 21, 28, 30 bis 32, 35, 36, 44, 54 (`deploys check` in CLI.md), 61 (MCP- und Scan-Abschnitt), 67, 68 (deutsche Docs), 74, 130, 132, 133, 135 bis 137, 140, 145, 109 bis 127 (Ideen).

## Prüfung

`build-docs.py`, `check-site.py` (65 Seiten, nur Längenwarnungen), `check-links.py`, `check-strings.py`, `check-docs.py`, `check-release.py` und `tests/install-tests.sh` laufen grün.
