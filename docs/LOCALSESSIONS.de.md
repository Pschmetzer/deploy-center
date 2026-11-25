# Sitzungszähler

20 oder 30 Claude-Code-Sitzungen gleichzeitig sind in Ordnung. Nicht in Ordnung: zehn Aufgaben, die im selben Moment
als zehn Sitzungen starten, wo eine bis drei Sitzungen sie nacheinander abarbeiten könnten, oder dieselbe Aufgabe
doppelt. `deploys localsessions` zählt die Sitzungen auf diesem Mac, findet zusammen gestartete Aufgaben auf einem Repo,
markiert doppelte und untätige und listet die überzähligen zum Schließen. Sie beendet nie selbst eine Sitzung.

Englisch, mit allen Details: [LOCALSESSIONS.md](LOCALSESSIONS.md)

## Im Terminal

```bash
deploys localsessions                 # jede Sitzung: PID, untätig seit, CPU, RAM, Zustand, Titel und Ordner; doppelte, untätige, Hinweis
deploys localsessions --json          # dasselbe für Skripte, die App und den MCP-Server (deploys_sessions)
deploys localsessions stop 4242 --yes # diese Sitzung beenden; die Transkript-Datei bleibt, die Claude-App zeigt sie evtl. als gestoppt
```

Markiert wird: mehr als drei Sitzungen auf einem Repo, jede höchstens 10 Minuten nach der vorigen gestartet (die
überzähligen zum Schließen), derselbe Titel zweimal, zwei Sitzungen im selben Ordner und Sitzungen ohne Aktivität seit
mehr als 60 Minuten. Gelb wird die Zahl erst ab 30 Sitzungen.

```bash
deploys localsessions set max-local 30   # gelb ab so vielen Sitzungen auf diesem Mac
deploys localsessions set bundle-to 3    # so viele Sitzungen dürfen zusammen gestartete Aufgaben nutzen
deploys localsessions set burst-min 10   # „zusammen“: jede höchstens so viele Minuten nach der vorigen, auf einem Repo
deploys localsessions set idle-min 60    # untätig nach so vielen Minuten
```

## In der Menüleiste

Im Menü steht „Claude Code: 24 auf diesem Mac · Cloud: unbekannt“ mit grünem oder gelbem Punkt. Darunter das Menü
„Aufgaben bündeln“ mit den zusammen gestarteten Gruppen und ihren überzähligen Sitzungen, den doppelten, den Sitzungen im
selben Ordner und den untätigen; ein Klick fragt nach
und beendet dann die Sitzung. Ohne diesen Klick wird nichts beendet.

## Cloud-Sitzungen: unbekannt

Cloud-Sitzungen lassen sich von diesem Mac aus nicht zählen: Weder die Claude-CLI noch die Dateien der Desktop-App
sagen, welche gerade laufen. Die App merkt sich nur die IDs der Cloud-Sitzungen, die eine lokale Sitzung gestartet
hat, ohne Zustand und Zeit; im Web oder am Telefon gestartete stehen gar nicht auf dem Mac. Deshalb steht dort
„unbekannt“ statt einer geratenen Zahl. Details in [LOCALSESSIONS.md](LOCALSESSIONS.md).
