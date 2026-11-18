# Aus der App deployen

Die deutsche Fassung von [DEPLOY-FROM-APP.md](DEPLOY-FROM-APP.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Nichts wird deployt, bis du Projekte anhakst, **Live deployen** drückst und bestätigst. Diese Seite sagt, was du dabei siehst.

## Bevor du drückst: die Kosten

Die untere Leiste zeigt ungefähr, was die angehakten Vercel-Builds kosten. Es ist eine Schätzung aus deinen bisherigen Builds, angezeigt, bevor etwas startet.

## Die Bestätigung

**Jetzt live schalten?** listet auf, was live geht. Dazu kann stehen:

- die neueste Commit-Nachricht jedes Projekts mit wartenden Änderungen (bis zu 5; im Demo-Modus verborgen),
- ein Hinweis, wenn ein Projekt schon auf dem neuesten Commit ist (der Build kostet und ändert nichts),
- was die Builds kosten und ob dein Budget hält,
- eine Warnung für ein Projekt, das vor weniger als 5 Minuten deployt wurde, und für ein wartendes Projekt, dessen neuester Commit über 30 Tage alt ist,
- deine eigenen Markierungen an den Projekten (eine Notiz, „kritisch“).

Bei mehr als 3 Projekten, rotem Risiko oder einer Markierung ist **Abbrechen** die Standardtaste, damit Return dich nicht aus Versehen live schaltet.

Nach dem Bestätigen kann **Einstellungen → Deploy → Warten, bevor ein Deploy startet** dir ein paar Sekunden zum Abbrechen geben. Siehe [SETTINGS.de.md](SETTINGS.de.md).

## Kopieren

**Liste kopieren** in der Bestätigung legt die Projekte, die live gehen sollen, in die Zwischenablage. Das Zeilenmenü hat **Zusammenfassung kopieren**: Name, Plattform und was wartet, in einer Zeile.

## Kosten

**Kosten …** öffnet das Kosten-Blatt: eine Kurve über 7 oder 14 Tage, das teuerste Projekt der Woche, ein Monatsbudget je Projekt mit Ampel (Rechtsklick auf ein Projekt), eine Schätzung „was wäre bei einem Build am Tag“ und ein Markdown-Bericht zum Kopieren. Eine Monatsgrenze für die CLI ist `deploys budget set 50` ([CLI.de.md](CLI.de.md)).

Das Menüleisten-Symbol wird zu einem Dollarzeichen, wenn der Monat im aktuellen Tempo über dem Budget liegt.

## Nach einem Deploy

Jeder Deploy steht im [Journal](JOURNAL.de.md). Die Liste aktualisiert sich, während ein Deploy läuft, und **Einstellungen → Deploy → Seite nach dem Live-Gang beobachten** prüft die Seite ein paar Minuten.
