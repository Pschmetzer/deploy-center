# Sichere Deploys

Die deutsche Fassung von [SAFE-DEPLOY.md](SAFE-DEPLOY.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Wenn KI-Agenten 30 bis 50 Mal am Tag pushen, soll nicht jeder Push live gehen. Deploy Center kann diese Pushes
zu einem Deploy bündeln, und vier Prüfungen halten dieses Deploy sicher:

1. **Grüne CI**: Mit `deploy-changed --when-green` gehen nur Commits live, deren Checks durchgelaufen sind (auch Commits ganz ohne Checks gehen live; in der App hält eine rote CI kein Deploy zurück).
2. **Health-Check mit Rollback**: Ist die Seite nach dem Deploy kaputt, geht Produktion zurück.
3. **Deploy-Fenster**: Zu Zeiten deiner Wahl (Freitagnachmittag, Feiertage) gibt es keine Deploys, es sei denn, du nennst einen Grund.
4. **Risiko-Ampel**: Ein roter Punkt, wenn der wartende Diff Migrationen, einen sehr großen Diff oder Ähnliches enthält.

Alle vier funktionieren im Terminal (`deploys …`) und in der App.

## 1. Deployen, wenn CI grün ist

```bash
deploys deploy-changed --when-green --yes
```

Für jedes Projekt mit Änderungen liest die CLI den kombinierten Status und die Check-Runs des Head-Commits
über `gh api`:

| CI | Was passiert |
| --- | --- |
| grün (alles bestanden, übersprungen oder neutral) | deployt, genau auf diesem Commit |
| gar keine Checks | deployt, denn es gibt nichts, worauf zu warten wäre |
| ausstehend (irgendetwas noch in der Warteschlange oder am Laufen) | nach 10 s, 20 s, 40 s … erneut gefragt (höchstens 2 Minuten Abstand), bis zu `--wait` (Standard `30m`) |
| rot (ein Fehler, Timeout, Abbruch, Aktion nötig) | übersprungen, mit den fehlgeschlagenen Checks |
| GitHub nicht erreichbar | wie ausstehend behandelt; übersprungen, sobald `--wait` abläuft |

Zwei Einstellungen stimmen die Regel ab. `DEPLOYS_CI_GRACE` (Standard 90 Sekunden): Ein Commit, der jünger ist und noch keinen Check hat, gilt als „CI hat nicht begonnen“, also als ausstehend, nicht als „keine Checks“; erhöhe den Wert für langsame Runner, was bei `--when-green --strict` in CI wichtig ist. `DEPLOYS_CI_IGNORE`: ein regulärer Ausdruck für Check-Namen, die nicht zählen, etwa für einen optionalen Check, der immer rot ist (`DEPLOYS_CI_IGNORE='^(codecov|lint-optional)'`); ohne ihn hält ein solcher Check jedes Deploy zurück.

Alle Projekte werden in Runden geprüft, damit eine langsame CI die anderen nicht aufhält. Ein Projekt startet,
sobald sein eigener Commit grün ist. Deployt wird der geprüfte Commit (`--sha`); ein Push, der während des Wartens
eintrifft, geht im nächsten Lauf live, nicht ungeprüft in diesem.

```bash
deploys deploy-changed --when-green --wait 45m --yes --json
```

Das liefert einen Eintrag pro Projekt: `{"platform","name","action":"started|skipped|failed","reason","id","url"}`.
Ohne `--yes` zeigt es nur, was es deployen würde.

Für einen einzelnen Commit:

```bash
deploys ci owner/repo <sha-or-branch> [--wait 10m] [--json]
```

Der Exit-Code ist 0 bei grün oder ohne Checks, 1 bei rot und 2, wenn Checks noch ausstehen oder
GitHub nicht erreichbar ist. Mit `--json` ist der Exit-Code immer 0, und das Urteil steht in der Antwort.

**In der App** hält eine rote CI nie ein Deploy zurück: Die Zeile zeigt „CI ist rot“ mit den fehlgeschlagenen
Checks, und Deployen startet es trotzdem. Der Schalter „Only when checks are green“ wurde entfernt.

## 2. Health-Check mit automatischem Rollback

```bash
deploys verify <project> [--path /health] [--rollback-after 10] [--no-rollback] [--url https://…] [--json]
```

1. Wartet, bis das neueste Produktions-Deploy live ist (wie `deploys watch`). Ist das Deploy fehlgeschlagen, gibt es nichts zu prüfen.
2. Ruft die Seite auf, dazu `--path`, wenn angegeben, 3-mal im Abstand von 5 s.
3. Der Check schlägt nur fehl, wenn **alle drei** Antworten 5xx sind oder gar keine kommt (Timeout oder
   keine Verbindung). Ein frischer Render-Dienst kann ein paar Sekunden lang mit 502 antworten. Weiterleitungen werden verfolgt.
   Ohne `--path` ist ein 4xx kein Fehler: Meist ist es eine geschützte Seite, und ein Rollback
   würde daran nichts ändern. Mit `--path` muss die Adresse existieren: Ein 4xx dort (ein fehlendes `/health`)
   zählt ebenfalls als Fehler.
4. Bei einem Fehler zählt es herunter (`Rolling back web in 10 s – Ctrl-C to stop`) und führt dann
   `deploys vercel|render rollback` aus. Strg-C stoppt das Rollback. `--no-rollback` meldet nur.

| Exit | Bedeutung |
| --- | --- |
| 0 | gesund |
| 1 | der Check schlug fehl und Produktion wurde zurückgerollt |
| 2 | der Check schlug fehl und nichts wurde zurückgerollt (`--no-rollback`, Strg-C oder das Rollback schlug fehl) |
| 3 | nichts wurde geprüft: unbekanntes Projekt, das neueste Deploy ist nicht live, keine Adresse, eine falsche Option |

Das Rollback, oder das gestoppte Rollback, kommt ins Journal.

Beispiel, nach einem Deploy aus einem Skript:

```bash
deploys deploy web && deploys verify web --path /api/health
```

**In der App** öffnest du die Details eines Projekts und setzt den Haken bei **Zurückrollen, wenn der Check fehlschlägt**. Das gilt
pro Projekt und wird auf diesem Mac gespeichert. Die App prüft die Seite nach dem Live-Gang ohnehin, mit dem Pfad
„Seiten für die Prüfung nach dem Deploy“. Ist der Haken gesetzt, startet ein 5xx oder keine Antwort einen 10-Sekunden-Countdown,
angezeigt als Mitteilung (auch wenn die App vorne ist) und als Zeile im Fenster,
beide mit **Abbrechen**. Läuft der Countdown ab, geht Produktion auf das Deploy davor zurück.
Ein 404 startet kein Rollback, und die Prüfung nach einem Rollback ebenso wenig.

**Einstellungen → Deploy → Seite nach dem Live-Gang beobachten** fragt einige Minuten lang (jede
Minute) statt nur einmal. Zwei fehlgeschlagene Antworten hintereinander warnen, oder lösen ein Rollback aus, wo das Projekt von selbst
zurückrollt. Antwortet die Seite langsamer als vor dem Deploy, sagt die App das. Die Details zeigen
die Uptime aus diesen Prüfungen (30 Tage, nur dieser Mac), und einmal am Tag warnt die App, wenn das
Zertifikat der Seite innerhalb von zwei Wochen abläuft. Die Pfade, die gefragt werden, stehen im Zeilenmenü: **Seiten für die Prüfung nach dem
Deploy …**.

## 3. Deploy-Fenster / Freeze

`~/.config/deploys/window.json` (oder `$DEPLOYS_CONFIG/window.json`):

```json
{
  "deny": [
    { "days": ["fri"], "from": "15:00" },
    { "days": ["sat", "sun"] },
    { "from": "22:00", "to": "06:00", "reason": "nobody is awake to fix it" },
    { "dates": ["2026-12-24", "2026-12-31"] }
  ]
}
```

- `days`: `mon` … `sun`. Weglassen heißt jeder Tag.
- `dates`: `YYYY-MM-DD`.
- `from` / `to`: Ortszeit, `HH:MM`. Standard sind `00:00` und `24:00`. Ist `from` später als `to`, läuft die Regel über Mitternacht.
- `reason`: der angezeigte Text. Ohne ihn wird die Regel beschrieben, z. B. `fri 15:00–24:00`.

In einem gesperrten Fenster weigern sich diese Befehle, Produktions-Deploys zu starten:

- `deploys deploy`
- `deploys deploy-changed --yes`
- `deploys vercel deploy`
- `deploys render deploy`
- `deploy-json`, das die App benutzt

Um trotzdem zu deployen, nenne einen Grund:

```bash
deploys deploy-changed --yes --force "hotfix for the login page"
```

Jedes so gestartete Projekt bekommt einen `forced`-Eintrag im Deploy-Verlauf (dem Journal der App),
mit dem Fenster und dem Grund. Diese gehen auch in einem Fenster live:

- Vorschauen (`--preview`)
- Rollbacks
- `verify` (ein Rollback ist eine Reparatur)

Autofix deployt nie (siehe [AUTOFIX.md](AUTOFIX.md)). Das Deploy des Fixes, nachdem du ihn gemergt hast, läuft durch das Fenster wie jedes andere.

```bash
deploys window          # Open / Closed, and which rule
deploys window --json   # {"denied":true,"reason":"fri 15:00–24:00",…}
```

`deploys window` beendet sich mit 1, solange das Fenster geschlossen ist. Mit `--json` immer mit 0.

**In der App** fragt Deployen in der Bestätigung zuerst nach, wenn das Fenster geschlossen ist: „Das Deploy-Fenster
ist zu“. Klicke auf **Trotzdem deployen …**, und nenne dann den Grund, der in den Deploy-Verlauf kommt.
**Einstellungen → Deploy → Deploy-Fenster** bearbeitet dieselbe `window.json`: eine Zeit hinzufügen (Tage, von, bis,
auch über Mitternacht), **Speichern**. Schlüssel, die der Editor nicht kennt, bleiben erhalten.

## 4. Risiko-Ampel

```bash
deploys risk <project> [--json]
```

Das bewertet den Diff zwischen dem, was live ist, und dem Branch (aus dem Vergleich von GitHub, höchstens 300
Dateien):

| Gefunden | Stufe |
| --- | --- |
| Migrationen: `migrations/`, `migrate/`, `prisma/`, `*.sql`, `schema.prisma`, `schema.rb` | rot |
| Lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `Cargo.lock`, `go.sum`, `composer.lock` | gelb |
| `.env` und `.env.*` | gelb |
| Konfiguration: `vercel.json`, `render.yaml`, `Dockerfile`, `docker-compose.yml`, `Procfile`, `next/vite/nuxt/astro/svelte/remix.config.*`, `.github/workflows/` | gelb |
| mehr als 500 geänderte Zeilen oder 30 Dateien | gelb |
| mehr als 3000 geänderte Zeilen oder mindestens 100 Dateien | rot |

Der schlimmste Fund bestimmt die Stufe.

```json
{"project":"web","platform":"vercel","level":"red","files":2,"lines":20,
 "reasons":[{"kind":"migrations","level":"red","files":["prisma/migrations/2/migration.sql"],"text":"database migrations: …"},
            {"kind":"lockfile","level":"yellow","files":["package-lock.json"],"text":"dependencies changed: …"}]}
```

Dieselbe Bewertung steckt in `deploys changed --json` und in den Listen, die die App liest (`risk`). Sie wird
aus dem Vergleich berechnet, der für die Commit-Zahl ohnehin gelesen wurde, und kostet daher keinen zusätzlichen GitHub-Aufruf.
`deploy-changed` ohne `--yes` nennt ein rotes Risiko neben dem Projekt.

**In der App** zeigt eine Zeile nur dann einen roten Punkt, wenn das Risiko rot ist. Gelb bleibt still. Die Details
zeigen die Stufe und jeden Grund.

## 4b. Secrets-Check

```bash
deploys secrets <project>
deploys secrets web && deploys deploy web --yes     # a gate in a script
git diff A..B | deploys secrets --stdin             # a diff you pipe in (GitLab, or any repo)
```

Das sieht nur die Zeilen an, die in dem, was auf den Live-Gang wartet, *hinzugefügt* wurden, mit denselben Mustern, die Logs maskieren (Keys, Tokens, private Schlüssel). Es gibt Dateinamen und die maskierte Zeile aus, nie das Geheimnis, und beendet sich mit `1`, wenn es eines findet. Es braucht `perl`. Für ein GitLab-Projekt leitest du einen Diff hinein. Das ist kein vollständiger Scanner: [SCAN.de.md](SCAN.de.md) behandelt `deploys check` (gitleaks und mehr).

## 5. Weitere Bremsen in der App

Alle freiwillig, in **Einstellungen → Deploy**, sofern nicht das Zeilenmenü genannt ist:

- **Vor dem Live-Gang von Datenbank-Migrationen ein Häkchen verlangen:** Ändern die wartenden Commits Migrations-
  dateien, fragt jedes Live-Deploy davon zuerst nach.
- **Vor riskanten Schritten nach Touch ID oder dem Passwort fragen:** mehrere Projekte auf einmal deployen, ein
  Rollback von Hand und Auto-Deploy erlauben. Das automatische Rollback nach einem fehlgeschlagenen Check
  wartet nicht darauf.
- **Kritische Projekte** (Zeilenmenü → **Kritisch: zum Live-Schalten Namen tippen**): Zum Live-Gehen musst du den
  Namen des Projekts eingeben.
- **Ein Budget pro Projekt** (Zeilenmenü → **Monatsbudget …**): USD pro Monat für seine Builds; eine Warnung
  kommt bei 80 % davon, im Tempo der Woche. Das Monatsbudget für alle Projekte steht in Einstellungen → Kosten.
- **Regeln** (Einstellungen → Deploy → Regeln): der Editor für `rules.json`, „wenn … dann deployen, halten oder
  melden“ (siehe [CLI.de.md](CLI.de.md)). Die App bearbeitet nur die Datei; `deploys deploy-changed
  --by-rules` wendet sie an.

## Tests

`tests/script-tests.sh` deckt alle vier ab, mit Attrappen für `gh`, `curl` und `vercel`, sodass kein
Netzwerk benutzt wird:

- CI, die grün, rot, langsam, nie fertig ist oder keine Checks hat
- die Fenster-Regeln, auch über Mitternacht
- `--force` und das Journal
- verify: gesund, wackelig, 5xx, Timeout, `--no-rollback` und Strg-C im Countdown
- die Risiko-Regeln

`DEPLOYS_NOW="fri 16:00 2026-11-13"` setzt die Zeit, die die Fenster-Regeln lesen. `DEPLOYS_JOURNAL`
legt fest, wohin die Journalzeilen gehen.
