# Mac-App: Stand der Umsetzung (Runde 7)

Branch `feat/app-round-7`. Nummern beziehen sich auf den Mac-App-Report (158 Funde).

## Umgesetzt
- Bugs: 1, 2, 3, 5, 7, 8, 9, 11, 14, 16, 19, 20, 21, 22, 23, 24
- Sicherheit: 25, 26, 28, 33, 37
- A11y: 44, 45, 53
- L10n: 60, 67
- Features: 121 (Repo öffnen, Repo- und Seitenadresse kopieren)

## Übersprungen oder offen
- 4, 6, 10, 12, 13, 15, 17, 18 (zentral `--` bricht ggf. den Argument-Parser des Skripts), 29–32, 34–36, 38: eigene Konzepte oder Eingriffe in `deploys`/Rechte, nicht risikoarm.
- 39–43, 46–52, 54–58: A11y-Rest, braucht Sichtprüfung in der laufenden App.
- 59, 61–66, 68–71: Lokalisierung, die Skript- und Textänderungen braucht.
- 72–87: Performance, Umbau auf `@Observable` u. a. zu groß ohne Messung.
- 88–113, 114–120, 122–140: UX und Features, je ein eigener Schritt mit UI-Test.
- 141–158: Refactorings, erst nach den Funktionsänderungen.

Geprüft: `./tests/app-tests.sh` (en und de) grün auf dem Stand dieses Commits.
