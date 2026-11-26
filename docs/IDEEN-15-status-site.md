# Runde 15, Block D: Status (Website, Docs, CI)

Nummern aus `docs/IDEEN-15.md`, Abschnitt D. Branch je Thema.

## Umgesetzt

- **D.A 1 bis 8:** Hostlisten (Startseite, FAQ, JSON-LD, llms.txt, Guides-Übersicht, READMEs, Marketplace, Raycast, Skills, Issue-Vorlage), Nicht-verbunden-Hinweise, SECURITY.md, SECURITY-MODEL und UNINSTALL für die acht neuen Hosts.
- **D.A 9, 12:** Drift-Test in `scripts/check-docs.py` (jeder Provider in Startseite, llms.txt, SECURITY.md, READMEs, Marketplace, Skills und im UNINSTALL-Schlüsselbund); `Disallow: /install/` in robots.txt.
- **D.I 110, 117, 120:** `external-links` läuft auch per `workflow_dispatch`; Smoke-Test prüft `/de/`, `/de/anleitungen/` und `/blog/feed.xml`; IndexNow-Fehler setzt eine Warnung.

## Bewusst nicht umgesetzt

- **D.I 109 (paths-Filter in ci.yml):** Ist ein Check als Pflicht eingetragen, kann ein PR mit übersprungenem Workflow nicht gemergt werden; ohne Zugriff auf die Branch-Einstellungen zu riskant.
