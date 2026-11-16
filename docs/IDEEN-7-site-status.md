# Runde 7: Website, Doku, Community (Stand)

Nummern aus dem Website/Doku/Tests-Audit. Branch `feat/site-docs-round-7`.

## Umgesetzt, erste Welle

- **Fehler und Widersprüche:** 1, 2 (JSON-LD, llms.txt; `check-release.py` prüft beides), 52, 53, 55, 56, 57, 58 (perl optional in `install.sh`), 59, 60, 70, 71, 72 (`build-docs.py`), 73.
- **install.sh:** 37 (Zeitlimits), 38 (Archivpfade), 39 (Versionsabgleich), 40 (genau eine Prüfsummenzeile), 43 (`--sha256`), 45 (`--dry-run`, `--quiet`), 138 (sudo-Zusammenfassung).
- **Web und A11y:** 18, 19, 24, 25, 26, 27, 29, 33, 34, 134.
- **SEO:** 3, 4, 6 bis 10 (fünf Guides), 15, 16, 17, 20 (nur `softwareHelp`), 22, 23, 128, 129, 131.
- **Doku und Community:** 61 (Host-Abschnitte, abgelehnte Deploys), 62, 63, 64 (`docs/providers/README.md`), 66 (`AGENTS.md`), 69, 75, 95, 107, 108, 139, 141, 142, 143.

## Umgesetzt, zweite Welle

- **54:** `deploys check` und `deploys config [--refresh]` in `docs/CLI.md`.
- **61:** MCP, Bug-Scan, Sicherheits-Check und Rollback in `docs/TROUBLESHOOTING.md`.
- **74:** `scripts/check-docs.py` gleicht die Zahl und Namen der Einstellungs-Tabs mit `app/SettingsSupport.swift` ab.
- **11 bis 13:** drei Guides (Build-Minuten und Queue, Deploy aus GitHub Actions, Previews für Bots und Agenten überspringen), ohne erfundene Zahlen.
- **14:** Hostseiten `docs/providers/vercel.md` und `render.md`, in `PAGES`, Matrix und `llms.txt`.
- **28:** Theme-Schalter und Kopier-Knöpfe auf Guides, Blog, Rechner und 404 (`site/js/site.js`).
- **30, 31, 32:** Rechner mit Zahlenfeldern, "Link kopieren" und Share-Sheet, Hinweis zu 22 Tagen gegen `deploys simulate`.
- **68:** deutsche Fassungen `docs/FAQ.de.md` und `docs/SAFE-START.de.md`. Die README ist schon auf Deutsch (`README.de.md`).
- **140:** CI-Badge in beiden READMEs.
- **65:** `docs/CLAUDE.md` heißt jetzt `docs/CLAUDE-IN-APP.md` (eigener Commit).

## Für den Merge von 65 (andere Forks)

Diese Stellen nennen noch den alten Pfad und müssen mit dem Merge angepasst werden:

- `deploys` Zeile 89 und Zeile 2163 (Kommentare: `docs/CLAUDE.md`)
- `examples/README.md` (Link `../docs/CLAUDE.md`). Bis dahin scheitern `build-docs.py` und `check-links.py`.
- `examples/claude-pr-ship-check.yml` Zeile 4 (Kommentar)

Mit diesen Änderungen laufen alle Prüfungen grün (lokal geprüft). `integrations/tests/claude-code.sh` Zeile 77 prüft nur, dass im Plugin keine CLAUDE.md liegt, und braucht nichts.

## Nicht umgesetzt

- **Fremdrevier:** Tests 76 bis 94 und 146 bis 150, CI, Issue-Templates, Release-Skripte (41, 42), Beispiel-Workflows (49 bis 51), Docker-Texte (46 bis 48, 144), `integrations/README.md` (Tippfehler), Statusseite und Badge, 136 (`dependabot.yml`).
- **Offen, größer oder nicht belegbar:**
  - 5 (Primärquellen-Links): keine URLs erfunden.
  - 21 (Tiefenlinks in die Guides), 35 (CSP per Meta: bräuchte Hashes aller Inline-Skripte), 36 (Suche auf Guides und Blog), 44 (versionierte install.sh-URL braucht ein Release-Asset).
  - 54 ist erledigt; 67 (CHANGELOG-Highlights) bleibt, weil `CHANGELOG.md` nur Struktur und Tippfehler ändern darf.
  - TROUBLESHOOTING.de (Teil von 68) ist nicht übersetzt, 74-Rest (nur Tabs geprüft), 130 (echte Änderungsdaten je Guide), 132 (Tab-Fokus folgt dem ARIA-Muster, bewusst belassen), 133 (Light-Theme-Variablen zusammenführen), 135 bis 137, 145 (Maintainer-Doku trennen), 109 bis 127 (Ideen).

## Prüfung

`build-docs.py`, `check-site.py` (70 Seiten, nur Längenwarnungen bei Titeln und Beschreibungen), `check-links.py`, `check-strings.py`, `check-docs.py`, `check-release.py` und `tests/install-tests.sh` laufen grün.
