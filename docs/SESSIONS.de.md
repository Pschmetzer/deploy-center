# Sitzungszähler

Viele Claude-Code-Sitzungen parallel sind schnell zu viele: Dieselbe Aufgabe läuft doppelt, Sitzungen stehen
stundenlang still, und das Limit für Cloud-Sitzungen ist erreicht. `deploys sessions` zählt die Sitzungen auf diesem
Mac, markiert doppelte und untätige und schlägt ab einer Grenze vor, Aufgaben zu bündeln: eine Sitzung, die mehrere
Aufgaben nacheinander abarbeitet, statt einer Sitzung pro Aufgabe. Sie beendet nie selbst eine Sitzung.

Englisch, mit allen Details: [SESSIONS.md](SESSIONS.md)

## Im Terminal

```bash
deploys sessions                 # jede Sitzung: PID, untätig seit, CPU, RAM, Zustand, Titel und Ordner; doppelte, untätige, Hinweis
deploys sessions --json          # dasselbe für Skripte, die App und den MCP-Server (deploys_sessions)
deploys sessions stop 4242 --yes # diese Sitzung beenden; das Transkript bleibt, sie lässt sich fortsetzen
```

Markiert wird: derselbe Titel zweimal (doppelte Aufgabe), zwei Sitzungen im selben Ordner, und Sitzungen ohne
Aktivität seit mehr als 60 Minuten. Ab 8 Sitzungen wird die Zahl gelb.

```bash
deploys sessions set max-local 8    # gelb ab so vielen Sitzungen auf diesem Mac
deploys sessions set idle-min 60    # untätig nach so vielen Minuten
```

## In der Menüleiste

Im Menü steht „Claude Code: 9 auf diesem Mac · Cloud: unbekannt“ mit grünem oder gelbem Punkt. Mit Hinweis gibt es
das Menü „Aufgaben bündeln“ mit den doppelten, den Sitzungen im selben Ordner und den untätigen; ein Klick fragt nach
und beendet dann die Sitzung. Ohne diesen Klick wird nichts beendet.

## Cloud-Sitzungen: unbekannt

Cloud-Sitzungen lassen sich von diesem Mac aus nicht zählen: Weder die Claude-CLI noch die Dateien der Desktop-App
sagen, welche gerade laufen. Die App merkt sich nur die IDs der Cloud-Sitzungen, die eine lokale Sitzung gestartet
hat, ohne Zustand und Zeit; im Web oder am Telefon gestartete stehen gar nicht auf dem Mac. Deshalb steht dort
„unbekannt“ statt einer geratenen Zahl. Details in [SESSIONS.md](SESSIONS.md).
