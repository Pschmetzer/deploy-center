# Leistungswächter

Viele Claude-Code-Sitzungen auf einem Mac gehen gut, bis ein Dutzend davon gleichzeitig `tsc`, `vitest` oder
`next build` startet: Der Speicher läuft voll, macOS swappt, und der ganze Mac hängt. Der Leistungswächter zeigt, wie
voll der Mac ist, und hält schwere Befehle zurück, bis Platz ist. Er beendet nie eine laufende Sitzung.

Englisch, mit allen Details: [PERF.md](PERF.md)

## Die Anzeige lesen

In der Menüleiste steht neben dem Deploy-Center-Symbol ein Punkt:

| Punkt | Bedeutet | Was tun |
| --- | --- | --- |
| grün | Speicherdruck normal, kein Swappen, Last unter einem Prozess pro Kern. | Alles starten. |
| gelb | Ausgelastet: Speicherdruck auf „warn“, etwas Swappen, mehr als 3 GB Swap belegt, Last über einem Prozess pro Kern, oder die Grenze für schwere Checks ist erreicht. | Schwere Checks warten kurz, bis die Bremse sie durchlässt. |
| rot | Überlastet: Speicherdruck kritisch, Swap fast voll und wächst, Last über 4 pro Kern. | Nichts Schweres mehr lokal starten. Alte Sitzungen archivieren, Arbeit in Cloud-Sitzungen geben. |

Das Menü zeigt darunter den Grund, die drei größten Verbraucher (zum Beispiel „Checks and builds (26) – 7,3 GB“),
wie viele Claude-Code-Sitzungen und schwere Checks laufen und ob ein schwerer Check gerade starten darf.

Im Terminal: `deploys perf status`. Abschalten in den Einstellungen → Allgemein → „Auslastung des Macs zeigen“.

## Die Lastbremse

`deploys perf gate -- npm run verify` startet den Befehl erst, wenn Platz ist (höchstens 10 Minuten warten). Der
Claude-Code-Hook (`integrations/claude-code/hooks/perf-gate.sh`) macht das automatisch für `tsc`, `vitest`, `eslint`,
`next build`, `playwright`, `npm run verify|test|build|typecheck|lint` und ähnliche. Leichte Befehle laufen sofort.
Bleibt der Mac die ganze Wartezeit rot, startet der Befehl nicht, und Claude bekommt den Hinweis, später oder in einer
Cloud-Sitzung weiterzumachen.

## Hängende und verwaiste Prozesse

Alles, was Speicher kostet, gehört zu einer Klasse mit einer Regel: Prüfläufe (Lint, Typecheck, Tests, Builds),
Test-Browser, MCP-Server, `npm exec`-Reste und Dev-Server. `deploys perf reap` zeigt, was hängt oder verwaist ist,
`--all` alle mit Klasse und Einstufung, `--yes` beendet. Selbst beendet (nach `deploys perf install --reap --yes`, alle
5 Minuten, mit Mitteilung) wird nur Eindeutiges: ein Prüflauf, der über 45 Minuten ohne CPU-Fortschritt oder über
90 Minuten läuft (bei Rot kürzer, nie unter 15), und Prozesse, deren Sitzung weg ist. Ungenutzte Dev-Server werden nur
gemeldet. Im Menü unter „Prozesse“ stehen zuerst die hängenden, verwaisten und ungenutzten, dann die größten, jeweils
mit Klasse, Laufzeit, Speicher und „Beenden“. Claude, dein Chrome, Datenbanken, Docker und alles unter einem Editor
oder Debugger werden nie angefasst.

## Docker und andere Verbraucher

`deploys perf consumers` zeigt Docker-Stacks, gebootete Simulatoren und die Größe wachsender Caches (Caches werden nur
gemeldet, nie gelöscht). Im Menü unter „Docker“ hat jeder laufende Stack „Stoppen“ und jeder vom Wächter gestoppte
„Wecken“; `deploys perf stop <stack> --yes` und `deploys perf wake <stack>` machen dasselbe im Terminal. Gestoppt
wird nur mit `docker stop`: Container, Volumes und Daten bleiben. Automatisches Stoppen nach 2 Stunden ohne Benutzung
(bei Gelb 1 Stunde, bei Rot 30 Minuten) ist aus und wird mit `deploys perf install --docker --yes` eingeschaltet;
Stacks unter `"docker": {"always": [...]}` in `~/.config/deploys/perf.json` bleiben immer an.

## Speicherplatz

`deploys disk` zeigt, wohin der Platz geht: Build-Ordner alter Worktrees, Docker, Paket-Caches (npm, pnpm, Yarn,
bun, pip, Homebrew), Xcode, `~/Library/Caches`, Papierkorb, Claude-Code-Verläufe und die Ordner der Claude-App.
Gemessen wird parallel und mit Zeitlimit, das Ergebnis bleibt 6 Stunden gespeichert. `deploys disk free --yes`
räumt nur, was von selbst wiederkommt (`deploys clean --docker`, npm-, pnpm-, Yarn- und Homebrew-Cache, Xcode
DerivedData älter als 7 Tage, nicht mehr verfügbare Simulatoren); ohne `--yes` wird nichts gelöscht. Papierkorb,
Docker-Volumes und -Container, Claude-Verläufe (dafür `cleanupPeriodDays` in `~/.claude/settings.json`), die Ordner
der Claude-App und `~/.cache/huggingface` werden nur angezeigt. `deploys disk schedule on --yes` lässt den
Lastwächter das automatisch tun, wenn weniger als 100 GB frei sind (`minFreeGB` in `~/.config/deploys/disk.json`).
In der Mac-App: Deploy → Speicher freigeben.

## Entlasten bei Speicherdruck

`deploys perf install --clean --shed --yes` schaltet es ein (Standard: aus), `deploys perf shed` zeigt, was gerade
gestoppt würde. Wird der Speicher knapp (Speicherdruck „warn“, Swappen, wenig freier Speicher oder Swap; hohe Last
allein zählt nicht), stoppt der Agent höchstens alle 5 Minuten bis zu 3 Dev-Server (`next dev`, `vite` …), die
niemand mehr braucht: deren Claude-Sitzung archiviert ist, deren Sitzung fertig ist und an deren Port seit
30 Minuten kein Client hing, oder die ohne Sitzung, Terminal und Claude-Prozess 30 Minuten unbenutzt sind. Dazu
ungenutzte Docker-Stacks ohne Datenbank. Jeder Stopp kommt als Mitteilung und ins Protokoll. Nie gestoppt: Claude,
Chrome, Datenbanken, launchd-Jobs. Das hilft über Spitzen; ist der Mac den ganzen Tag voll, gehören Sitzungen in die
Cloud.

## Dev-Server fertiger Arbeit

`deploys perf install --clean --shed --stop-finished --yes` stoppt unabhängig von der Last Dev-Server, deren
Claude-Sitzung archiviert oder fertig ist oder deren Branch-PR gemergt oder geschlossen ist, nach 10 Minuten Karenz,
mit Mitteilung und Protokolleintrag. `deploys perf finished` zeigt sie vorher.

## MCP-Server

`deploys perf mcp` zeigt die MCP-Server aller Claude-Code-Sitzungen nach Name: Prozesse, Speicher, in wie vielen
Sitzungen, und wie oft ihre Tools in den letzten 7 Tagen aufgerufen wurden (aus den Sitzungsverläufen, nur lesend).
Dazu ein Vorschlag, wo ein Server aus sein könnte. Geändert wird nichts; Abschalten entscheidest du. Die Mac-App zeigt
dasselbe im Leistungs-Panel.

## Apps beenden

Einstellungen → Allgemein → „Ausgewählte Apps beenden, wenn der Mac überlastet ist“ (Standard: aus) zeigt die
laufenden Apps mit ihrem Speicher und einen Vorschlag „Nicht benötigt?“ zum Übernehmen mit einem Klick. Deploy Center
muss laufen, und Entlasten (`--shed`) muss an sein. Beendet wird nur bei Rot mit Speicherdruck seit 5 Minuten, nachdem das Entlasten oben seine Chance hatte,
eine App nach der anderen, die größte zuerst, nur im Hintergrund und mindestens 30 Minuten unbenutzt, und nur wie ⌘Q:
Mit ungesicherten Dokumenten bleibt die App offen. Optional auch ihre fensterlosen Helfer (nur TERM, nie Systemdienste
oder launchd-Jobs). Jede App kommt als Mitteilung mit Name und Speicher und ins Protokoll. Nie: Claude, Terminal,
iTerm, Xcode, Simulator, Finder, Deploy Center. `deploys perf clean` zeigt, was beendet würde.

`deploys perf gate` startet schwere Befehle bei Gelb oder Rot mit niedriger Priorität (`taskpolicy -b`);
`"lowPriority": false` in `perf.json` schaltet das ab.

## Aufräumer

`deploys perf clean` listet verwaiste Dev-Prozesse (alte Checks ohne Elternprozess, Prozesse in gelöschten
Worktrees), `--yes` beendet sie. `deploys perf install --yes` richtet einen launchd-Agenten ein, der jede Minute misst,
bei mehr als 5 Minuten Rot eine Mitteilung mit den größten Verbrauchern schickt und alle 10 Minuten aufräumt (nur
Bericht, mit `--clean` auch beenden). Protokoll: `~/.config/deploys/perf/clean.log`.
