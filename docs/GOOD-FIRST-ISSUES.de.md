# Good first issues (Deutsch)

Die deutsche Fassung von [GOOD-FIRST-ISSUES.md](GOOD-FIRST-ISSUES.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Kleine, in sich abgeschlossene Aufgaben für einen ersten Pull Request. Die Eigentümerin oder der Eigentümer kann jede
zu einem Issue mit dem Label `good first issue` machen. Lies bitte zuerst [CONTRIBUTING.md](../CONTRIBUTING.md) (englisch): keine
echten Projektnamen in Beispielen, Texte auf Englisch und Deutsch, nichts baut ohne `--yes`. Jede Aufgabe sagt, was zu tun ist,
wo, und wann sie fertig ist. Für alles, was Nutzer bemerken, kommt eine Zeile unter `## Unreleased` in `CHANGELOG.md`.

## Screenshots

1. **Mehr Screenshots.** Mach einen Screenshot der Menüleiste und der Einstellungen im **Demo-Modus** (Einstellungen → Allgemein),
   leg sie in `docs/images/` ab und nutze sie mit einer Bildunterschrift in [SAFE-START.md](SAFE-START.md) (englisch).
   *Fertig, wenn:* die Seite beide Bilder zeigt und keins einen echten Namen enthält.

2. **Screenshots für die Raycast- und VS-Code-Einträge.** Beide Store-Einträge haben noch keine; mach sie im Demo-Modus.
   *Fertig, wenn:* die Dateien dort liegen, wo `integrations/raycast/PUBLISHING.md` und `integrations/vscode/PUBLISHING.md` sagen, dass
   Einträge sie nehmen, und kein echter Name darauf steht.

## Doku

3. **Ein Fehlerbehebungs-Eintrag aus einem echten Fehler.** Such eine Fehlermeldung in [`deploys`](../deploys), die noch nicht in
   [TROUBLESHOOTING.md](TROUBLESHOOTING.md) steht, und schreib, was sie bedeutet und was zu tun ist (suche den genauen Text mit `grep`).
   *Fertig, wenn:* die Meldung wörtlich zitiert ist und Ursache und nächster Schritt ein kurzer Absatz sind.

4. **Eine deutsche Seite für die Team-Doku.** [TEAM.md](TEAM.md) hat keine deutsche Fassung. Schreib `docs/TEAM.de.md` im Stil von
   [FAQ.de.md](FAQ.de.md) (sie beginnt mit einer Zeile, die das englische Original nennt; Befehle und Dateinamen bleiben), verlinke sie in
   `docs/README.md` und trag sie in `ALIAS` in `scripts/check-docs.py` ein. *Fertig, wenn:* `python3 -I scripts/check-docs.py` besteht.

5. **Eine deutsche Seite für GitLab.** Dasselbe für [GITLAB.md](GITLAB.md): `docs/GITLAB.de.md`, verlinkt in `docs/README.md`. `glab`,
   `GITLAB_TOKEN` und die Befehle bleiben unübersetzt.

6. **Eine deutsche Seite für Deploy-Fenster.** Dasselbe für [SAFE-DEPLOY.md](SAFE-DEPLOY.md): `docs/SAFE-DEPLOY.de.md`. Das
   `window.json`-Beispiel bleibt, wie es ist; übersetze, was die Felder bedeuten.

7. **Der Rest des deutschen Glossars.** [GLOSSARY.de.md](GLOSSARY.de.md) hat nur die neueren Einträge. Übersetze die älteren aus
   [GLOSSARY.md](GLOSSARY.md), die fehlen (zum Beispiel Git-Verbindung, Rollback, Blueprint und Build-Minuten), in derselben Reihenfolge.
   *Fertig, wenn:* jede `##`-Überschrift der englischen Seite eine deutsche hat.

8. **Gegenlesen durch Muttersprachler.** Lies [FAQ.de.md](FAQ.de.md) und [FIRST-START.de.md](FIRST-START.de.md) laut und bessere steife
   oder maschinell klingende Sätze aus. Befehle, Dateinamen und Zahlen bleiben. *Fertig, wenn:* der Diff nur Fließtext berührt.

9. **Die CLI-Installation von Grund auf probieren.** Folge [README-CLI.md](../README-CLI.md) in einem frischen Ubuntu-Container (oder WSL)
   Wort für Wort. Wo ein Schritt fehlt oder falsch ist, korrigiere die Seite; was ein Fehler im Skript ist, melde als Issue, statt es zu umgehen.

## Beispiele und Tests

10. **Die Beispiele in CI laufen lassen.** [examples/config/validate.sh](../examples/config/validate.sh) prüft die fertigen Konfigurationen
    ohne Konto. Verpacke es als `tests/examples-tests.sh`, trag es in `tests/suites.txt` ein und gib ihm einen Schritt in
    `.github/workflows/ci.yml` (`tests/release-tests.sh` prüft, dass beide übereinstimmen). *Fertig, wenn:* `bash tests/all.sh --list` es zeigt
    und die Suite besteht.

11. **Ein Beispiel für eine gemeinsame Konfiguration mit Fenster.** Leg `examples/config/deploy-center-window.json` an: eine
    [deploy-center.json](TEAM.md#1-shared-config-deploy-centerjson) mit einem gemeinsamen `window` (eine Liste: ein offenes genügt) und
    `approvals` für ein Projekt, mit erfundenen Namen. Nimm sie in die Schema-Prüfung von `validate.sh` auf.

12. **Ein Hook, der ein lokales Protokoll schreibt.** Leg `examples/config/hooks.d/post-deploy-log` an: eine Zeile je Start (UTC-Zeit,
    Plattform, Projekt, sha, Zustand), angehängt an eine Datei, deren Pfad aus einer Variable kommt, ohne Netzwerk. Gib `validate.sh` eine Prüfung,
    die ihn mit den Variablen startet, die `deploys` setzt, und die Zeile zurückliest.

13. **Ein Provider-Test für eine fehlgeschlagene Anmeldung.** Such dir einen Host in `tests/providers/` aus, leg unter `tests/fixtures/<host>/`
    eine Fixture für eine 401-Antwort an und teste, dass der Provider das sagt, statt eine leere Liste auszugeben. Der Vertrag steht in
    [PROVIDERS.md](PROVIDERS.md).

## Größer, aber in sich abgeschlossen

14. **Ein Git-Host.** [GITHOSTS.md](GITHOSTS.md) sagt, was ein neuer Host liefert. Nimm Bitbucket oder Gitea: die drei Funktionen
    `*_head_of`, `*_pending_of` und `*_open_prs_of`, einen Test im Stil von `tests/providers/gitlab.sh` und eine Doku-Seite wie [GITLAB.md](GITLAB.md).

15. **Eine Anleitung für die Website.** Schreib `site/guides/<slug>/index.html` darüber, Deploys am Freitagnachmittag mit `deploys freeze` zu
    sperren (Quellen: [SAFE-DEPLOY.md](SAFE-DEPLOY.md), [FAQ.md](FAQ.md)). Wo eine neue Anleitung überall eingetragen wird (Sitemap, `llms.txt`,
    Fußzeilen, verwandte Links), steht in [CONTRIBUTING.md](../CONTRIBUTING.md#website). *Fertig, wenn:* `python3 -I scripts/check-site.py` und
    `scripts/check-links.py site` bestehen.
