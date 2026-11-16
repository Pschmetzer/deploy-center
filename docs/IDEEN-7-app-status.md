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
