# Mac-App: Stand der Umsetzung (Runde 7)

Branch `feat/app-round-7`. Nummern beziehen sich auf den Mac-App-Report (158 Funde).
Geprüft: `./tests/app-tests.sh` (en und de) grün auf dem Stand jedes Commits.

## Umgesetzt

- **Bugs:** 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 16, 19, 20, 21, 22, 23, 24
- **Sicherheit:** 25, 26, 28, 29, 30, 31, 33, 36, 37, 38
- **A11y:** 39, 40, 41, 42, 43, 44, 45, 49, 50, 51, 52, 53, 58
- **L10n:** 59, 60, 65, 66, 67, 68, 69, 71
- **Perf:** 72, 76, 81
- **UX:** 88, 92, 106
- **Features:** 114, 121, 137 (schon vorhanden: 138 als `Store.rollbackSeconds`)
- **Code:** 144

## Bewusst ausgelassen, mit Grund

- 12: kein Anbieter in der App teilt heute eine ID zwischen Plattformen (Platform kennt nur Vercel und Render, deren IDs verschieden sind). Erst nötig, wenn ein dritter Anbieter in die App kommt.
- 13: ein Test (`stats: dora`) legt fest, dass ein Rollback eine Störung eröffnet, bis ein guter Deploy folgt. Die Gegenthese des Reports widerspricht dem; `perWeek` bleibt, weil das Journal auch Lücken ohne Deploys enthält.
- 15: ob „offline“ oder „abgemeldet“ vorliegt, entscheidet `deploys doctor` (providers/vercel.sh, `whoami` braucht Netz). Das Skript ist nicht Teil dieser Runde.
- 17: Namen unter 3 Zeichen nicht zu maskieren ist Absicht: sonst würde „ui“ oder „db“ in jedem Fließtext ersetzt.
- 18: `--` an den Aufrufstellen: das Skript wertet `--` nicht überall als Optionsende; `Store.safeArg` bleibt der Schutz.
- 32: der Freigabe-Handshake braucht ein neues Protokoll im MCP-Server (integrations/mcp), nicht in der App.
- 34: eine DNS-Auflösung vor jedem Logo-Abruf blockiert; sauber geht es nur über eine eigene URLSession-Konfiguration mit Auflösungsprüfung, die nicht ohne Netztest abgesichert werden kann.
- 35: eine Umgebungs-Allowlist bräche GH_TOKEN, RENDER_API_KEY, AWS_* und die Anthropic-Schlüssel, die das Skript aus der Umgebung liest.
- 46, 47, 48, 54, 55, 56, 57: brauchen Sichtprüfung in der laufenden App (Layout, Kontrast, Fokusreihenfolge); per Code und Test nicht abzusichern.
- 61: `--lang` wertet das Skript nur bei `ai notes` aus, nicht bei `explain` und `ship`.
- 62: der englische Standard-Prompt ist beabsichtigt, Claude versteht ihn in jedem Chat.
- 63, 64: `methodGerman` und die Fehlertexte hängen am Wortlaut des Skripts; stabile Schlüssel müsste `deploys` liefern.
- 70: Mehrzahlregeln per `String(localized:)` brauchen einen Katalog für alle Texte; die App hat bisher keinen.
- 73: UserDefaults liest aus dem Speicher; nicht messbar.
- 74, 75, 79, 84, 85, 86: Umbau auf `@Observable`, neues Speicherformat und Hintergrund-Decoding berühren den ganzen Store; ohne Messung kein Gewinn belegt.
- 77, 78: nicht als Engpass gemessen.
- 80: gebündelter Status-Aufruf braucht ein neues Skript-Kommando.
- 82, 83: Zwischenspeicher im Store bringt kaum etwas; offen.
- 87: `searchPath` wird einmal pro Tag gelesen und in UserDefaults gehalten; nur der erste Start des Tages zahlt.
- 89, 90, 91, 93–105, 107–113: je eigener UI-Schritt (Countdown-Toast, Wiederholen der Fehlgeschlagenen, Notiz in der Bestätigung, Zeitwähler, Auswahllisten); jeder braucht Layout und Sichtprüfung. 91 braucht zusätzlich den Store im Bestätigungsblatt.
- 115–120, 122–136, 139, 140: neue Funktionen mit eigenem Datenmodell (Journal-Felder, Kosten-Zeitraum, Wochenplan, Pro-Projekt-Einstellungen); nicht risikoarm ohne UI-Test.
- 141–143, 145–158: Refactorings über große Dateien (Store, Model); ohne Sichtprüfung und bei laufender Funktionsarbeit nicht sicher.

## Runde 8 (Branch `feat/app-round-8`, auf dem Stand von PR #138)

Geprüft: `bash tests/app-tests.sh` (en und de) grün nach jeder der drei Gruppen. `./build.sh` nicht ausgeführt.

### Umgesetzt

- **Code:** 141 teilweise (`Model.swift` verliert `Notify.swift` und `DeployWindowConfig.swift`; `Store.swift` bleibt eine Klasse, weil die Abschnitte gespeicherte Eigenschaften teilen), 142, 143 (`Decoding.swift`: `Lossy`, `AnyKey`, `Skippable`, `Lax` einmal), 146 (`Store.allItems`, `Store.item(key:)`), 147 (`Pasteboard.copy`, mit `concealed`), 148 teilweise (`Timing` für die sieben Wartezeiten des Stores), 151 (`PrivateFile.write`: 0600 schon beim Anlegen, atomar; für `window.json`, `rules.json`, `messages.json` und die Bilanz), 153 (`ProjectColor`), 154 (`DeployState`: eine Tabelle für Zeilen- und Laufwort).
- **Features:** 117 (Journal-Einträge tragen `sha` und `deployId`; alte Zeilen lesen weiter; Anzeige und „Commit kopieren“), 118 teilweise (Zeitraum und Plattform; Datumsbereich frei wählbar fehlt).
- **UX:** 89 („Alle abbrechen“ im Start-Toast ab zwei Zeilen), 90 und 129 (die fehlgeschlagenen Projekte werden genannt, ein Klick startet sie nochmal; nicht für Beobachter), 91 teilweise (Notiz und „kritisch“ stehen in der Bestätigung; Risikogründe und CI standen dort schon bzw. fehlen weiter), 108 (ein alter Fehler-Toast lässt nach zwei Minuten los).

### Weiter offen, mit Grund

- 119 (Kosten-Zeitraum wählbar): Budgetalarm und Tempo rechnen mit den 14 Tagen; ein anderer Zeitraum bräuchte einen zweiten Abruf und eigene Alarmlogik.
- 73, 74, 75, 77–79, 82–87: nicht gemessen oder ein Umbau des Store auf `@Observable`; ohne Messung kein belegter Gewinn.
- 93–105, 107, 109–113, 115, 116, 120, 122–128, 130–136, 139, 140: je eigener Bildschirm mit Layout und Sichtprüfung (Zeitwähler, Auswahllisten, Pro-Projekt-Einstellungen, Wochenpläne, Verlauf der Antwortzeit); ohne laufende App nicht belegbar.
- 141 (Rest), 145, 149, 150, 152, 155–158: Store in weitere Dateien teilen verlangt, dass gespeicherte Eigenschaften und `private`-Zugriffe neu geordnet werden; `ProjectMarks`-Modell, `FileWriter`-Actor und Initializer-Injektion statt `nonisolated(unsafe)` sind je eigene Umbauten mit Testumbau.
- 46–48, 54–57: Sichtprüfung (Layout, Kontrast, Fokusreihenfolge).
- 12, 13, 15, 17, 18, 32, 34, 35, 59, 61–64, 70, 80: Gründe wie oben in Runde 7 (Skript oder MCP-Server nötig, oder Gegenbeleg).
