# Zusatzbefehle

Kleine Befehle neben den großen. Jeder liegt in einer eigenen Datei, `lib/x-<name>.sh`, damit `deploys` selbst klein bleibt.
`deploys more` listet sie mit je einer Zeile, `deploys more <Befehl>` zeigt die Anwendung eines Befehls. Keiner startet einen
Build, einen Deploy oder einen Rollback; die, die etwas schreiben (eine Sicherungsdatei, eine Kalenderdatei), sagen es und
schreiben nur dorthin, wohin du zeigst.

English: [EXTRAS.md](EXTRAS.md)

```bash
deploys more                # alle Zusatzbefehle, je eine Zeile
deploys more heatmap        # die Anwendung eines Befehls
deploys more --json         # für Skripte
```

## heatmap und trend: das Journal als Bild

```bash
deploys heatmap                      # 12 Wochen, Montag oben: · keine, ░ wenige, ▒ einige, ▓ viele, █ am meisten, ! ein Fehlschlag an dem Tag
deploys heatmap --weeks 26 --project web
deploys trend                        # je Projekt eine Sparkline: Deploys pro Tag der letzten 30 Tage, Fehlschläge darunter
deploys trend web --days 14 --json
```

Gezählt wie bei [`deploys digest`](CLI.md), in UTC. Gelesen wird nur das Journal.

## Einen neuen hinzufügen

`lib/x-<name>.sh` neben `deploys` legen. Die Datei definiert `x_<name>_main` (Bindestriche im Namen werden zu Unterstrichen)
und sagt in einer Kopfzeile, was sie ist: `# x-command: <name> | <was er tut> | <Anwendung>`. Die Tests kommen nach
`tests/x/<name>.sh`; `tests/x-tests.sh` führt alle aus.
