# Bug-Scan: Claude durchsucht ein Repo und öffnet einen Fix-PR

Die deutsche Fassung von [SCAN.md](SCAN.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

„Mit Claude nach Bugs suchen“ (Rechtsklick auf eine Zeile oder in den Details des Projekts) führt die Claude-Code-CLI **auf diesem Mac** gegen das Repository des Projekts aus. Claude sucht nach echten Bugs, behebt bis zu fünf, führt Build und Tests aus, und Deploy Center öffnet einen Pull Request mit einem Bericht. Nichts wird von selbst gemergt oder deployt. Es braucht keine Routine und nichts in claude.ai.

```
click ──> deploys scan start <owner/repo> <branch>   (returns at once)
            └─ fresh worktree of the repo, branch claude/scan-<repo>-<sha7>
                 └─ claude -p (its own login), edits + build/test commands only
                      ├─ no change   ──> "nothing to fix"
                      └─ changes     ──> commit, push, gh pr create (report as the PR body)
```

## Einrichtung (einmalig)

```bash
npm i -g @anthropic-ai/claude-code
claude login
```

Der Scan nutzt die eigene Anmeldung der CLI, zum Beispiel ein Claude-Abo. Ein `ANTHROPIC_API_KEY` in der Umgebung wird bei Scans ignoriert, damit nicht versehentlich pro Token abgerechnet wird. `gh` muss angemeldet sein, denn es klont und öffnet den PR.

## Regeln

- **Nur Bugs.** Keine Stiländerungen, Refactorings, Umbenennungen oder neuen Abhängigkeiten. Alles, bei dem Claude sich nicht sicher ist, steht im PR unter „Not changed“, statt geändert zu werden.
- **Nur deine eigenen Repos.** Der Scan führt Build- und Test-Befehle des Repos (`npm run`, `npm install`, `pytest`, …) auf diesem Mac aus, mit deinen Rechten. Scanne nur Repos, denen du vertraust, so wie du es vor einem `npm install` darin tun würdest. Die eigenen Claude-Einstellungen, Hooks und MCP-Server des Repos werden ignoriert (`claude --restricted --strict-mcp-config`), Datei-Werkzeuge bleiben im Worktree des Scans, und nur geänderte Dateien und neue Testdateien kommen in den PR.
- **Begrenzte Werkzeuge.** Lesen, Suchen und Bearbeiten, dazu Build-, Test- und Lint-Befehle und Git nur lesend. Kein Push, kein `rm`, keine Netzwerk-Werkzeuge. Committen, Pushen und das Öffnen des PR erledigt `deploys`, nicht Claude. Ein Scan wird nach 90 Minuten beendet (`DEPLOYS_SCAN_TIMEOUT`).
- **Einer nach dem anderen.** Kein zweiter Scan eines Repos, solange einer läuft oder ein Scan-PR davon offen ist. Höchstens 4 Scans pro 24 Stunden (`DEPLOYS_SCAN_PER_DAY`).
- **Der Mac muss wach sein.** Ein Scan dauert 10 bis 30 Minuten. Einer, dessen Prozess weg ist (Neustart, Ruhezustand), wird als fehlgeschlagen markiert.
- **Mergt nie, deployt nie.** Du prüfst den PR. Nach dem Merge deployst du wie gewohnt.

## Einstellungen (Umgebung)

| Variable | Standard | |
|---|---|---|
| `DEPLOYS_SCAN_MODEL` | `sonnet` | Modell, das an `claude --model` übergeben wird |
| `DEPLOYS_SCAN_MAX_FIXES` | `5` | Fixes pro Scan |
| `DEPLOYS_SCAN_PER_DAY` | `4` | Scans pro 24 Stunden |
| `DEPLOYS_SCAN_TIMEOUT` | `5400` | Sekunden, bis ein Scan beendet wird |
| `DEPLOYS_SCAN_DIR` | `~/.config/deploys/scan` | Klone, Worktrees, Berichte |
| `DEPLOYS_SCAN_FOREGROUND` | nicht gesetzt | `1`: `scan start` und `check start` laufen im Vordergrund statt als Hintergrundprozess. Setze es in CI, sonst kann der Job enden, bevor der Scan fertig ist |

## Befehle

```
deploys scan start <owner/repo> [branch]
deploys scan status --json      installed, logged in, the newest scans
deploys scan list               the same as a table
deploys scan log <id>           Claude's report of one scan
```

## Sicherheits-Check: OSV-Scanner, gitleaks und Semgrep

„Sicherheits-Check“ (Rechtsklick auf eine Zeile oder in den Details des Projekts) führt drei kostenlose Werkzeuge auf einer frischen Kopie des Repos aus, auf diesem Mac:

| Werkzeug | Findet | |
|---|---|---|
| OSV-Scanner | Pakete mit bekannten Schwachstellen (Lockfiles, requirements) | kostenlos, Open Source; fragt `api.osv.dev` mit den Paketnamen und Versionen |
| gitleaks | Keys und Passwörter im Code und im Git-Verlauf | kostenlos, offline |
| Semgrep CE | Bug- und Sicherheitsmuster im Code (`p/default`, Metriken aus) | kostenlose CLI; lädt die `p/default`-Regeln aus der Semgrep-Registry |

```bash
brew install osv-scanner gitleaks semgrep
```

Nur gitleaks arbeitet ganz offline. OSV-Scanner sendet die Namen und Versionen deiner Abhängigkeiten an `api.osv.dev`, und Semgrep holt seine Regeln von `semgrep.dev`; kein Quellcode und kein Secret verlässt den Mac ([SECURITY.md](../SECURITY.md#what-is-sent-where)). Ein fehlendes Werkzeug wird als fehlend angezeigt; die anderen laufen trotzdem. Der Check führt **keinen Code des Repos** aus und ist deshalb auf jedem Repo sicher.

**„Mit Claude beheben“** neben dem Ergebnis startet einen Bug-Scan (oben) mit den Funden von OSV und Semgrep: Regel, Datei, Zeile und Meldung, höchstens 30, keine Code-Ausschnitte. Bei einem verwundbaren Paket darf der Scan dieses Paket auf eine behobene Version anheben, die einzige Ausnahme von „keine neuen Abhängigkeiten“.

**Secrets bleiben auf diesem Mac.** gitleaks läuft mit `--redact`; nur Regel, Datei, Zeile und Commit werden behalten, nie der Wert. Funde von Secrets (gitleaks und die Secret-Regeln von Semgrep) werden nie an Claude weitergegeben und nie in einen PR geschrieben: Bei einem öffentlichen Repo würde dieser PR auf das Leck zeigen, und ein Commit entfernt einen Key ohnehin nicht aus dem Verlauf. Die App listet sie als „diese Keys erneuern“.

```
deploys check start <owner/repo> [branch]
deploys check show <id>                          findings (secrets redacted)
deploys scan start <owner/repo> [branch] --findings <id>
```

| Variable | Standard | |
|---|---|---|
| `DEPLOYS_SEMGREP_CONFIG` | `p/default` | Semgrep-Regeln |
| `DEPLOYS_CHECK_TIMEOUT` | `900` | Sekunden pro Werkzeug |

## Nächtliche Prüfung: jedes Repo, nur was neu ist

Einstellungen > Claude > „Nächtliche Prüfung“ oder `deploys nightly schedule on` führt den Sicherheits-Check von oben einmal pro Nacht (standardmäßig 03:00) auf jedem Repo deiner Projekte aus, eins nach dem anderen, über launchd. Ein Mac, der schläft, führt ihn beim Aufwachen aus. Beide Schalter sind standardmäßig **aus**.

- **Die erste Prüfung eines Repos ist sein Ausgangspunkt.** Was schon da ist, wird vermerkt, nicht gemeldet und nicht an Claude geschickt; nutze dafür „Mit Claude beheben“ bei einem Check.
- **Nur neue Funde zählen.** Jeder Fund bekommt einen Fingerabdruck (OSV: Datei, Paket, Version und Hinweise; Semgrep: Regel, Datei und Meldung, ohne die Zeile, da Zeilen wandern). Ein Fund wird einmal gemeldet, nicht jede Nacht.
- **„Claude behebt neue Funde“** (`deploys nightly fix on`): Neue verwundbare Pakete und neue Semgrep-Funde mit Schweregrad `ERROR` (oder `CRITICAL`, `HIGH`) gehen an einen Bug-Scan (oben) mit **nur diesen Funden**, höchstens 2 pro Nacht (`DEPLOYS_NIGHTLY_MAX_SCANS`) und innerhalb der täglichen Scan-Obergrenze. Ein Scan, der abgelehnt wird (ein offener Scan-PR des Repos, die Obergrenze), lässt seine Funde für die nächste Nacht neu bleiben. Er öffnet einen PR; er mergt und deployt nie.
- **Geleakte Keys werden nur gemeldet**, wie beim manuellen Check: erneuere sie.
- **Eine Mitteilung** am Ende, und keine, wenn nichts neu ist. Ein Fund steht einmal in einer Mitteilung, auch während er auf einen Scan wartet; ein Check, der immer wieder fehlschlägt, wird gemeldet, wenn er anfängt zu scheitern.
- Pausierte und ignorierte Projekte bleiben außen vor, ebenso ein Repo, das du auslässt (`deploys nightly skip <owner/repo>` oder „Auslassen“ in der App). Nur GitHub-Repos.
- Build-, Typ- und Testfehler (tsc, ESLint, die Testsuite) gehören nicht zur nächtlichen Prüfung: Sie brauchen `npm install`, und das führt unbeaufsichtigt Code des Repos aus. Der Bug-Scan führt sie aus, wenn er etwas behebt.

### Wöchentliche Prüfung der Änderungen der Woche

`deploys nightly review on [1-7]` (oder „Claude prüft die Änderungen der Woche“ in der App, standardmäßig aus) fügt dem nächtlichen Lauf einmal pro Woche eine Prüfung hinzu (standardmäßig Sonntag; 1 ist Montag). Für jedes Repo, dessen Branch sich seit der letzten Prüfung bewegt hat, bekommt Claude einen Bug-Scan mit dem Auftrag, `git diff <last reviewed commit>..HEAD` zu lesen und nur nach Bugs zu suchen, die diese Änderungen gebracht haben. Beim ersten Mal ist die Basis der letzte Commit, der älter als eine Woche ist.

- Geänderte Dateien kommen aus dem Klon, den die nächtliche Prüfung geholt hat; Lockfiles, Doku und Bilder zählen nicht, und eine Woche, in der sich nur sie geändert haben, startet keinen Scan. Keine Commit-Nachrichten kommen in den Prompt.
- Sie **teilt sich das nächtliche Limit** (`DEPLOYS_NIGHTLY_MAX_SCANS`, 2) mit den Fixes, Fixes zuerst. Prüfungen, die nicht mehr passen, warten auf die nächsten Nächte; bei vielen Repos braucht eine Prüfwoche also mehrere Nächte.
- Der geprüfte Commit rückt erst weiter, wenn der Scan gelaufen ist (ein PR oder „nothing to fix“). Ein abgelehnter Scan wartet; ein fehlschlagender wird zweimal versucht und wartet dann auf die nächste Woche. Kein Repo wird innerhalb von fünf Tagen zweimal geprüft.

```
deploys nightly schedule on [HH:MM] | off     the launchd job (log: ~/Library/Logs/DeployCenter-nightly.log)
deploys nightly fix on | off                  new findings to a Claude bug scan
deploys nightly review on [1-7] | off         the weekly review of the week's changes
deploys nightly skip | unskip <owner/repo>
deploys nightly list                          the repos a run checks
deploys nightly run | start                   one run now (start: in the background)
deploys nightly status --json                 settings and the last run per repo (no finding text)
```
