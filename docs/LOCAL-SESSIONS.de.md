# Sitzungszähler

20 oder 30 Claude-Code-Sitzungen gleichzeitig sind in Ordnung. Nicht in Ordnung: zehn Aufgaben, die im selben Moment
als zehn Sitzungen starten, wo eine bis drei Sitzungen sie nacheinander abarbeiten könnten, oder dieselbe Aufgabe
doppelt. `deploys local-sessions` zählt die Sitzungen auf diesem Mac, findet zusammen gestartete Aufgaben auf einem Repo,
markiert doppelte und untätige und listet die überzähligen zum Schließen. Sie beendet nie selbst eine Sitzung.

Englisch, mit allen Details: [SESSIONS.md](LOCAL-SESSIONS.md)

## Im Terminal

```bash
deploys local-sessions                 # jede Sitzung: PID, untätig seit, CPU, RAM, Zustand, Titel und Ordner; doppelte, untätige, Hinweis
deploys local-sessions --json          # dasselbe für Skripte, die App und den MCP-Server (deploys_local_sessions)
deploys local-sessions stop 4242 --yes # diese Sitzung beenden; die Transkript-Datei bleibt, die Claude-App zeigt sie evtl. als gestoppt
```

Markiert wird: mehr als drei Sitzungen auf einem Repo, jede höchstens 10 Minuten nach der vorigen gestartet (die
überzähligen zum Schließen), derselbe Titel zweimal, zwei Sitzungen im selben Ordner und Sitzungen ohne Aktivität seit
mehr als 60 Minuten. Gelb wird die Zahl erst ab 30 Sitzungen.

```bash
deploys local-sessions set max-local 30   # gelb ab so vielen Sitzungen auf diesem Mac
deploys local-sessions set bundle-to 3    # so viele Sitzungen dürfen zusammen gestartete Aufgaben nutzen
deploys local-sessions set burst-min 10   # „zusammen“: jede höchstens so viele Minuten nach der vorigen, auf einem Repo
deploys local-sessions set idle-min 60    # untätig nach so vielen Minuten
```

## In der Menüleiste

Im Menü steht „Claude Code: 24 auf diesem Mac“ (Cloud-Sessions haben eine eigene Zeile) mit grünem oder gelbem Punkt. Darunter das Menü
„Aufgaben bündeln“ mit den zusammen gestarteten Gruppen und ihren überzähligen Sitzungen, den doppelten, den Sitzungen im
selben Ordner und den untätigen; ein Klick fragt nach
und beendet dann die Sitzung. Ohne diesen Klick wird nichts beendet.

## Cloud-Sitzungen

Cloud-Sitzungen, wie GitHub sie sieht (gemergt, wartend, hängend), zeigt `deploys sessions` und das Fenster
„Cloud-Sessions“. Wie viele Cloud-Sitzungen gerade laufen, lässt sich auf dem Mac nicht lesen: Weder die Claude-CLI noch
die Dateien der Desktop-App sagen es, und GitHub sieht nur beobachtete Repos und nur Sitzungen, die schon gepusht haben.
Deshalb steht im JSON „unbekannt“ statt einer geratenen Zahl. Details in [LOCAL-SESSIONS.md](LOCAL-SESSIONS.md).

## Desktop-Sitzungen aller Konten

`deploys desktop-sessions [--json]` zeigt die Code-Sitzungen der Claude-Desktop-App für jedes auf diesem Mac
angemeldete Konto: offen, fertig aber noch offen, wartet auf dich, läuft. Nur lesend. Fertig heißt: alle Pull Requests
gemergt oder geschlossen, nichts läuft, niemand wird gefragt, nicht `review_ready` oder `blocked`. Archivieren macht
die Claude-App selbst: in jedem Konto „Auto-archive sessions when their pull request closes“ einschalten
(Einstellungen → Claude Code). Details in der englischen Fassung.
