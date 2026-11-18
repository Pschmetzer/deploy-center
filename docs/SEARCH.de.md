# Suche und gespeicherte Suchen

Die deutsche Fassung von [SEARCH.md](SEARCH.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Das Suchfeld über der Liste filtert beim Tippen: Namen, Repos, Notizen, Branch und Commit-Text. Während der Suche zeigt das Feld, wie viele Zeilen passen („3/41“).

## Operatoren

Operatoren stehen neben gewöhnlichen Wörtern. Alles, was kein Operator ist, wird als Text gesucht.

| Operator | Zeigt |
| --- | --- |
| `is:failed` | Projekte, deren letzter Build fehlschlug |
| `is:waiting` | Projekte mit wartenden Commits |
| `host:render` (oder `platform:render`) | nur ein Anbieter; der Name ist der CLI-Name der Plattform, etwa `vercel` oder `render` |
| `repo:my-repo` | Projekte eines Repos |

Beispiele (ausgedachte Namen):

```text
is:failed host:render        fehlgeschlagene Render-Dienste
is:waiting repo:my-shop      was in einem Repo wartet
is:failed checkout           fehlgeschlagene Projekte, die „checkout“ erwähnen
```

Ein Operator mit unbekanntem Anbieternamen wird als normaler Text gesucht.

## Gespeicherte Suchen

Der Lesezeichen-Knopf neben dem Feld merkt sich die aktuelle Suche, etwa `is:failed host:render`. Ein Klick auf eine gespeicherte Suche führt sie erneut aus; du kannst sie auch entfernen. Eine gespeicherte Suche ist nur Text auf diesem Mac; sie zu starten deployt nie etwas.

## Repo-Gruppen

Projekte desselben Repos stehen unter einem Repo-Kopf. Ein Klick auf den Kopf klappt ihn zu (der Zustand wird gemerkt). Ein Kopf zählt seine fehlgeschlagenen Projekte und bietet **Fehlgeschlagene N anhaken** neben **Alle N anhaken**, wenn nur einige fehlschlugen. **Mehr → Alle Repo-Gruppen zuklappen** und **aufklappen** wirken auf alle Köpfe.

## In der Befehlspalette

Die Befehlspalette hat **Nur fehlgeschlagene (an/aus)** und eine Zeile je gespeicherte Suche. Eine Zeile füllt das Suchfeld; es läuft nichts. Wahl-Befehl-F tut dasselbe wie **Nur fehlgeschlagene**. Rechtsklick auf einen Repo-Kopf bietet **Nur dieses Repo zeigen**, das die Suche mit `repo:name` füllt.

## Logs durchsuchen

Die Befehlspalette hat **Logs fehlgeschlagener Projekte durchsuchen**: eine Suche über die Logs jedes fehlgeschlagenen Projekts. Ohne Suchtext gruppiert sie die Fehler nach derselben Fehlerzeile, zehn Projekte mit demselben Fehler erscheinen also als eine Gruppe. Es liest nur.

## Gemergte Fixes

Wird ein [Autofix](AUTOFIX.md)-Pull-Request gemergt, fällt seine Zeile auf, bis der Fix live ist. **Mehr → Die N gemergten Fixes anhaken** hakt alle an. Es hakt nur an; zum Deployen braucht es weiter deinen Klick.

## Liste kopieren

**Mehr → Liste der wartenden Projekte kopieren** legt eine Markdown-Liste dessen, was auf den Live-Gang wartet, in die Zwischenablage. Im Demo-Modus sind die Namen maskiert.
