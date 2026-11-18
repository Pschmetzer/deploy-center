# Das Deploy-Journal

Die deutsche Fassung von [JOURNAL.md](JOURNAL.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Jeder Deploy, jedes Rollback und jeder Abbruch, den Deploy Center startet, steht in einem Journal auf deinem Mac, eine Zeile je Vorgang: Zeit, Plattform, Projekt, Ergebnis und ein Detail. Fehlertexte werden maskiert, bevor sie geschrieben werden. Das Journal verlässt den Mac nie.

Wo es liegt: in der Journal-Datei der App (unter Linux im Konfigurationsordner); `DEPLOYS_JOURNAL` zeigt der CLI eine andere Datei.

## Prüfen

```bash
deploys journal verify          # ist die Kette heil?
deploys journal verify --json
```

Jede Zeile trägt den SHA-256 der Zeile davor (`prevHash`). Eine geänderte oder entfernte Zeile zeigt sich als gebrochenes Glied, und der Befehl endet mit `1`. Die erste Zeile wird nicht geprüft, weil die App die Datei von vorn kürzt.

## Exportieren

```bash
deploys journal export > journal.csv
deploys journal export --since 2026-11-01 --project my-shop > my-shop.csv
```

Die CSV hat die Spalten `at,platform,name,result,detail`. Text, den eine Tabellenkalkulation als Formel lesen könnte (beginnt mit `=`, `+`, `-` oder `@`), bekommt ein `'` davor; das Öffnen der Datei führt also nichts aus.

## Ein Monatsbericht

```bash
deploys journal report                   # dieser Monat
deploys journal report --month 2026-10   # ein anderer Monat
```

Der Bericht ist Markdown: wie viele Einträge, eine Tabelle der Ergebnisse und eine der Projekte mit ihren Eintragszahlen. Ohne Einträge steht dort „Nothing in this month.“, ohne Journal „No journal yet.“ (englisch).

Siehe auch [CLI.de.md](CLI.de.md) und [TEAM.md](TEAM.md) (`deploys team journal`).
