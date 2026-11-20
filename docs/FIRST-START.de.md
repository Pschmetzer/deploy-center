# Erster Start

Die deutsche Fassung von [FIRST-START.md](FIRST-START.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Was beim ersten Öffnen von Deploy Center zu sehen ist und was jeder Schritt tut. Nichts davon ändert ein Projekt, bevor du einen Knopf drückst und bestätigst.

Der Rundgang hat drei Schritte: **Überspringen** schließt ihn, **Zurück** und **Weiter** wechseln den Schritt, und du zeigst ihn mit **Erststart-Anleitung wieder zeigen** in Einstellungen → Hilfe erneut an.

## 1. Nur ansehen

Die App liest deine Projekte von Vercel, Render und GitHub und zeigt, wie viele noch bei jedem Push bauen. Sie ändert nichts. Fehlt etwas Nötiges, steht das dort, statt „verbunden“.

Der Rundgang nutzt deine echten Projekte, keine Demo. Für Screenshots oder eine Bildschirmfreigabe schaltest du in Einstellungen → Allgemein den **Demo-Modus** ein: Projektnamen, Repos und Domains werden durch Platzhalter ersetzt.

## 2. Ein Trockenlauf

Der zweite Schritt fragt „Was würde Auto-Deploy kosten?“: Er zählt die Pushes auf den Deploy-Branch jedes Projekts bei GitHub und rechnet jeden als einen Build zum Durchschnitt des Projekts. Du kannst 7 bis 90 Tage zurückschauen. Es ist eine Schätzung und ändert nichts. Dieselbe Schätzung ist `deploys simulate` ([SAVINGS.md](SAVINGS.md)).

## 3. Erst ein Projekt

Such dir ein Projekt aus, das ein wenig warten darf. Auto-Deploy geht nur dafür aus, du bestätigst in einem Dialog. Der Rest bleibt, wie er ist. Ein Push baut dieses Projekt nicht mehr; du deployst es aus der App.

Zurücknehmen: [AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy).

## Nach dem Rundgang

- Auto-Deploy für eine ganze Plattform schaltest du mit dem Knopf über der Liste aus.
- [SAFE-START.de.md](SAFE-START.de.md) zeigt dieselben drei Schritte im Terminal.
- Fehlt eine Verbindung oder erscheint ein Fehler, such ihn wörtlich in [TROUBLESHOOTING.de.md](TROUBLESHOOTING.de.md).
- Alle Einstellungen mit je einem Beispiel: [SETTINGS.md](SETTINGS.md).

## Wenn dir der Rundgang nicht reicht

Jedes davon ist eine Datei in deinem Konfigurationsordner (`~/.config/deploys`, `deploys where` zeigt ihn) und startet nichts von allein. Fertige Dateien zum Kopieren liegen in [examples/config/](../examples/config/); `sh examples/config/validate.sh` prüft sie ohne Konto.

- **Eine Zeit sperren.** `deploys freeze add fri 15:00 --reason "kein Deploy vor dem Wochenende"`, danach `deploys freeze`, um es nachzulesen ([SAFE-DEPLOY.md](SAFE-DEPLOY.md), englisch).
- **Kosten begrenzen.** `deploys budget set 50` hält `deploy-changed --yes` an, bevor es über 50 $ Vercel-Kosten im Monat geht ([CLI.de.md](CLI.de.md)).
- **Kleines von allein live gehen lassen.** Eine Regel in `rules.json` und `deploys rules check`, um zu sehen, was sie täte ([CLI.md](CLI.md#rules), englisch).
- **Eigenes Skript ausführen.** Eine `pre-deploy`- oder `post-deploy`-Datei in `hooks.d` ([CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd), englisch).
- **Ein Monorepo, das alles baut.** Der Ignored Build Step von Vercel: [examples/config/vercel-ignored-build-step.sh](../examples/config/vercel-ignored-build-step.sh) und das [Glossar](GLOSSARY.md#ignored-build-step).
- **Fragen.** [FAQ.de.md](FAQ.de.md) hat kurze Antworten, [GLOSSARY.de.md](GLOSSARY.de.md) die Wörter.
