# Deploy Center – Ideen, Runde 14: Werkzeuge, Tests und CI (Stand 0.12.0)

Gegen IDEEN.md bis IDEEN-13.md abgeglichen. Diese Runde ist **Tooling**: nichts davon ändert, was Nutzer sehen,
nichts startet einen Build oder Deploy. Neue Dateien statt Umbauten. Status: ✅ umgesetzt, 🔧 in Arbeit, ⬜ offen.
Wird mit jedem PR dieser Spur nachgeführt.

## A. Tests

1. ✅ **App-Tests je Thema** – `tests/app-tests.swift` (2 183 Zeilen) ist `tests/app/*.swift`: `helpers.swift` (expect, item),
   eine Datei je Thema (`suite_<thema>()`), `main.swift` ruft sie nacheinander. Gleiche Zahl `expect(`-Aufrufe vor und nach der Teilung.
2. ✅ **CLI-Tests je Thema** – `tests/cli-tests.sh` ist ein Lader für `tests/cli/*.sh` (gleiche Reihenfolge, gleiche Shell:
   die Tests teilen sich den e2e-Zustand). `tests/suites.txt` und `tests/all.sh` unverändert.
3. ⬜ **Test-Zähler je Suite** – `tests/all.sh` zeigt neben der Zeit auch, wie viele `ok`-Zeilen eine Suite druckte; ein Sinken fällt auf.
4. ⬜ **Schnelle Teilmenge** – `tests/all.sh --changed`: nur die Suiten, deren Quelldateien sich gegen `origin/main` geändert haben
   (Abbildung Datei → Suite in `tests/suites.txt`).
5. ⬜ **Flaky-Erkennung** – die Nachtläufe zählen, welche Tests in zwei Läufen verschieden ausgehen, und melden sie.

## B. Bauen und Editor

6. ✅ **Package.swift** – `open Package.swift` gibt Xcode/SourceKit Vervollständigung, Sprung zur Definition und Fehler in `app/` und `shared/`.
   Nur für den Editor; der Release-Weg bleibt `build.sh`. Sparkle ist wie in `scripts/sparkle.sh` festgenagelt.
7. ✅ **swift-format** – `.swift-format` und ein CI-Schritt, der nie fehlschlägt (`continue-on-error`): die Zahl der Hinweise je Regel
   steht in der Zusammenfassung des Laufs. Der Code behält seine ausgerichteten Spalten; es ist ein Hinweis für neuen Code.
8. ✅ **Package.swift und build.sh einig** (`scripts/check-build.py`, CI-Schritt) – eine Prüfung, dass `platforms` in `Package.swift` und `MIN_OS` in `build.sh` dieselbe
   macOS-Version nennen und Sparkle dieselbe Version wie `scripts/sparkle.sh`.
9. ⬜ **Test-Ziel im Package** – die App-Tests als zweites Ziel, damit Xcode sie ausführen kann (braucht eine Bibliothek ohne `@main`).

## C. Skripte

10. ✅ **`scripts/new-provider.sh <host>`** – legt `providers/<host>.sh` (jede Funktion des Vertrags als Platzhalter),
    `tests/providers/<host>.sh` und `tests/fixtures/<host>/` an; überschreibt nichts. Der Test des Gerüsts läuft sofort durch,
    `tests/providers/contract.sh` schlägt für den Host fehl, bis die Fixtures echte Antworten liefern.
11. ✅ **`scripts/clean-worktrees.sh`** – listet veraltete `.claude/worktrees/*`; mit `--remove` entfernt es nur die, die sauber sind,
    keinen Commit außerhalb jedes Remote-Zweigs haben, in denen kein Prozess arbeitet und die länger als 24 Stunden ruhen.
12. ✅ **`scripts/export-strings.py`** – alle `L("EN","DE")`-Paare als TSV oder JSON für Übersetzer; `--check` findet sichtbare Texte
    (`Text("…")`, `Button("…")` …) ohne Paar, `--strict` lässt sie scheitern; Marken stehen in `scripts/export-strings-ignore.txt`.
13. ⬜ **Übersetzung zurückspielen** – `scripts/import-strings.py` liest eine bearbeitete TSV und setzt die deutschen Texte in die Quellen
    ein (nur dort, wo das Englisch noch übereinstimmt; Trockenlauf zuerst).
14. ✅ **Die Prüfung der Paare in CI** – `export-strings.py --check --strict` als Schritt neben `check-strings.py`.

## D. CI

15. ⬜ **Gemeinsamer Cache** für Homebrew-Pakete und `vendor/Sparkle` im macOS-Lauf (die macOS-Minuten zählen zehnfach).
16. ⬜ **Laufzeiten sichtbar** – die Zeit je Suite aus `tests/all.sh` in der Zusammenfassung des Laufs, ein Rückblick über die letzten Läufe.
17. ⬜ **Abhängigkeits-Updates** – Dependabot für GitHub-Actions-Pins (die Schritte sind auf Commit-Hashes festgenagelt).
18. ⬜ **Nur Dokumentation geändert** – Läufe überspringen die macOS-Tests, wenn ein PR nur `docs/` oder `site/` berührt.
