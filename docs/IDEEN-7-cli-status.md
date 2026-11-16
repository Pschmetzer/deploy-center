# Runde 7: CLI und Provider, Stand der Umsetzung

Quelle: Prüfbericht zu `deploys`, `lib/`, `providers/`, `scripts/`, Schema (156 Funde, Nummern A1–H156).
Branch: `feat/cli-round-7`. Nur das ist umgesetzt, was durch die Skript-Tests gedeckt ist.

## Umgesetzt

- **Bugs:** 1 (xargs mit NUL, Branchnamen mit Anführungszeichen), 2 (schreibgeschützter Config-Ordner stoppt
  lesende Befehle nicht mehr), 4 und 5 (CI-Urteil: Status anderer Plattformen zählen nicht, abgebrochene und auf
  Freigabe wartende Läufe sind "wartet", nicht "rot"; Ausnahme-Muster mit `DEPLOYS_CI_IGNORE`), 6 (`per_page=100`
  bei Commit-Status), 7 (verify: fehlender Wert ist eine Usage-Zeile), 8 (watch zählt die echte Zeit),
  9 und 10 (Start-Sperre: eindeutiger Name, Restzeit in der Meldung), 11 (Scan: unverfolgte Dateien zählen nicht
  als Änderung), 14 (`$SELF` statt `$0` für Hintergrundläufe), 16 (launchd: Warten nach `bootout`),
  17 (Cron-Zeile legt `~/.local/state` an), 18 (Fehlermeldungen auf stderr nutzen die stderr-Farben),
  22 und 23 (Repo-Zuordnung: Temp-Datei im selben Ordner, Sperre bei `remember_repo`; Render und Coolify
  ebenso beim Schreiben), 24 (`watch --timeout` ohne Projekt ist eine Usage-Zeile), 26 (doctor: ungültiges
  Provider-JSON macht die Ausgabe nicht unlesbar), 27 (Clone-URLs bleiben in maskierten Logs lesbar),
  28 und 29 (hooks install: erst schreiben, dann tauschen; Pfad per `%q`), 33 (release: Retry bei 404 des CDN),
  34 (bump: alle Vorprüfungen vor der ersten Änderung, Punkte der Version in sed escaped),
  35 (appcast: gleiches Release behält sein Datum), 143 bis 146 (Schema: `checks`, Gruppen mit `checks`/`stopOnFail`,
  Fensterliste und `dates`, Beobachter mit `until`, `tz`-Beschreibung stimmt mit dem Code überein).
- **Sicherheit:** 36 (Schlüsseleingabe am Terminal ohne Echo), 37 (Schlüssel aus der Umgebung mit Anführungszeichen,
  Backslash oder Zeilenumbruch wird abgelehnt, bevor er in curls Konfig kommt), 41 und 42 (mehr Token-Präfixe
  in der Maskierung, Passwörter mit `@` in URLs), 43 (Routine-ID nur Buchstaben und Ziffern),
  44 (API-Überschreibungen nur https, Ausnahme: diese Maschine und `.test`), 45 (`--sha` nur 7 bis 40 Hex-Zeichen),
  50 (`umask 077`), 52 (verify: nur http/https, Weiterleitungen nur auf https).
- **API:** 57 (Retry-After und Jitter in `http_call`), 58 (`HTTP_MAX_TIME`), 59 (PUT/PATCH/DELETE werden bei 5xx
  wiederholt, ein POST nie), 61 (curl-stderr getrennt von der Antwort der Routine, Beta-Header per
  `DEPLOYS_ROUTINE_BETA` änderbar), 69 (watch: nach 2 Minuten alle 15 s).
- **UX:** 88 (`NO_COLOR`, `TERM=dumb`, `CLICOLOR_FORCE`).

## Nicht umgesetzt

Alle übrigen Nummern. Gründe: zu groß für diese Runde (Provider-Parität D 73 bis 87, neue Provider und Features G),
brauchen Plattform-Fakten, die hier nicht prüfbar sind (mit "(prüfen)" markierte Punkte 32, 64, 65, 68, 75, 76,
40), oder ändern Verhalten, das Tests und App voraussetzen (102 Exit-Code ohne Argument, 108 Meta-Cache,
153 Tarball-Inhalt). Offen und lohnend als nächstes: 3 (Compare mit Head-SHA), 12 und 13 (Scan-Sperren, PID-Prüfung),
19 (`--when-green` bei Providern ohne `--sha`), 39 (Scan-Umgebung bereinigen), 47, 51, 104 (Top-Level `rollback`/`cancel`),
107 und 112 (Performance von `all_json` und `costs`).

## Hinweis zu den Tests

Der Ctrl-C-Test von verify braucht ein SIGINT, das in einem mit `&` gestarteten Hintergrundlauf ignoriert wird;
er schlägt dort fehl, ohne dass der Code schuld ist. Die `watch ends`-Tests haben 20 Sekunden und scheitern
bei sehr hoher Last. Beide einzeln und im Vordergrund prüfen.
