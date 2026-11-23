# Einstellungen, jeweils mit Beispiel

Die deutsche Fassung von [SETTINGS.md](SETTINGS.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Das Fenster Einstellungen hat die Reiter Allgemein, Plattformen, Projekte, Deploy, Kosten, Claude, iPhone, Team und Hilfe. Hier stehen die Optionen, die du am ehesten änderst, mit je einem ausgedachten Beispiel.

## Allgemein

| Option | Beispiel |
| --- | --- |
| Listen neu laden alle | 15 Minuten bei langsamer Verbindung: die App fragt Vercel, Render und GitHub seltener. |
| In der Menüleiste zeigen / Kein Dock-Symbol | Beides an: Deploy Center ist nur ein kleines Menüleisten-Symbol. |
| Beim Anmelden öffnen | An, wenn du jeden Morgen deployst. Ein Build ohne Developer-ID-Signatur kann kein Anmeldeobjekt sein. |
| Demo-Modus | An vor einer Bildschirmfreigabe: `my-shop` erscheint als Platzhalter. Kürzel ⇧⌘D. |
| Kompakte Liste | An bei 40 Projekten, um mehr Zeilen zu sehen. |
| Farbenblind-freundlich | Blau statt Grün für „live“. |
| Logos von den Projektseiten laden | Aus, wenn die App keine Symbole von deinen Projekt-Domains holen soll. |
| Sprache | Die App zwischen English und Deutsch umschalten. |

## Mitteilungen

| Option | Beispiel |
| --- | --- |
| Mitteilung, wenn ein Deploy fertig ist | „my-shop ist live“, sobald der Build durch ist. |
| Tägliche Erinnerung zum Deployen | 09:00: eine Mitteilung mit der Zahl wartender Commits. |
| Tagesabschluss | 17:00: was heute live ging und was noch wartet. |
| Wochenrückblick am Montag | Eine Mitteilung am Montag: die letzten 7 Tage gegen die 7 davor. Derselbe Rückblick steht in Einstellungen → Kosten. |
| Ruhezeit (von / bis) | 22:00 bis 07:00: dazwischen keine Mitteilung. |
| Nach 30 Minuten noch einmal erinnern | Ein Fehler, den du nicht geöffnet hast, kommt einmal wieder. |

## Deploy

| Option | Beispiel |
| --- | --- |
| Builds gleichzeitig | 2: zehn Projekte starten zwei Builds, dann die nächsten zwei. |
| Warten, bevor ein Deploy startet | 10 Sekunden: nach dem Bestätigen kannst du noch abbrechen. |
| Vor einem Einzel-Deploy fragen | An: „Deploy“ in der Zeile fragt noch einmal. |
| Warnen, wenn Commits länger warten als | 7 Tage: ein Projekt mit einer Woche altem Merge wird markiert. |
| Seite nach dem Live-Gang beobachten | 15 Minuten: jede Minute eine Prüfung; zwei Fehler hintereinander warnen, oder rollen zurück, wo das Projekt das selbst tut. |
| Neutrale Mitteilungen | An: „Ein Deploy ist fertig“ ohne Projektnamen, sicher auf dem gesperrten Bildschirm. |
| Vor riskanten Schritten nach Touch ID oder dem Passwort fragen | An: mehrere Projekte auf einmal deployen, ein Rollback von Hand und Auto-Deploy erlauben fragen nach Fingerabdruck oder Passwort. Das automatische Zurückrollen nach einem fehlgeschlagenen Check wartet nicht. |

## Kosten: Ziele und ruhende Projekte

| Option | Beispiel |
| --- | --- |
| Wochenziel für Deploys | 10: „Diese Woche: 7 von 10“ wird beim letzten Deploy orange und darüber rot. 0 schaltet es aus. Gezählt ab Montag. |
| Ruhende Projekte | Listet Projekte ohne Deploy seit 90 Tagen, als Kandidaten zum Pausieren. Dieselbe Liste im Terminal: `deploys idle`. |

## Budget

`deploys budget set 50` (oder der Abschnitt Budget) begrenzt die Vercel-Build-Ausgaben auf 50 $ im Monat: `deploy-changed --yes` hält an, bevor es darüber geht. Mit `--strict` auch, wenn die Ausgaben unbekannt sind. Siehe [CLI.de.md](CLI.de.md).

## Dateien hinter den Einstellungen

Die CLI legt ihre Einstellungen als Dateien in `~/.config/deploys/` ab; [CLI.md](CLI.md#settings) listet sie (englisch). Zum Beispiel sperrt `window.json` Deploys am Freitagnachmittag ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)). Einstellungen werden nirgends hin gesendet.

Hakt es? [TROUBLESHOOTING.de.md](TROUBLESHOOTING.de.md) hat jede Fehlermeldung wörtlich.
