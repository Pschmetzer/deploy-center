# Round 8: Integrationen und iPhone, Stand

Branch `feat/integrations-round-8`, ab `feat/improvements-round-7` (PR 138). Nummern wie in `STATUS-round-7.md`.

Getestet: `integrations/tests/run.sh` 529 ok, kein Fehler (1 Skip: Plugin-Hook-Test, weil die App hier installiert ist);
VS Code `npm test` 68/68; `ios/test.sh` und `ios/Tests/run.sh` grün; `ios/build.sh` (Simulator, unsigniert) baut ohne Fehler;
`scripts/check-public.sh` sauber; shellcheck (warning) auf allen geänderten Skripten sauber.

## Umgesetzt

- MCP: 11 (neue Tools `deploys_guard_status`, `deploys_allowed`; `deploys_logs` mit `id` und `runtime`), 12 (Resource-Templates
  `deploys://project/{name}/status|notes|history`), 14 (`outputSchema` an allen JSON-Tools; ein gekürzter Text bleibt gültig, er liefert
  `structuredContent` mit Hinweis), 8 (Start-Zähler pro Stunde in `<config>/mcp-starts.json`, 0600, `DEPLOYS_MCP_MAX_PER_HOUR`),
  17 (die zwei Listenaufrufe von `platformOf` werden 20 s wiederverwendet; Schreibwege nie), 139 (Hinweis zu „immer erlauben“),
  148 teilweise (Test: jedes Tool hat Titel, Beschreibung und ein strenges Eingabeschema).
- Plugin: 22 (`deploys-ship` liest Risiko, Fenster und CI vor der Rückfrage), 24 (Umgehungswege wie `vercel --prod`, Deploy-Hook-URLs,
  `gh workflow run` brauchen dasselbe OK; Hinweis im Skill), 25 (Hook wartet nach einem Push 8 s, beim Sitzungsstart 15 s).
  19, 20, 21 waren schon in Runde 7 erledigt.
- Notify: 30 (alle acht Formate in der Doku), 32 (Format `custom` mit jq-Vorlage in `DEPLOYS_NOTIFY_TEMPLATE`), 140 (Name auf zwei
  Plattformen erscheint als `plattform:name`).
- Statusseite: 73 (Feed-Einträge mit `<summary>`, eine nicht erreichbare Seite ist ein Eintrag), 74 (zweiter Versuch bei einer Seite,
  die nicht antwortet), 75 (`texts` überschreibt jeden Text; andere Sprachen nur über diese Texte).
- Badge: 78 (`<name>.json` als shields.io-Endpoint neben jeder SVG).
- Action: 52 (Eingaben `strict` und `by-rules`), 53 (Ausgabe `plan` beim Trockenlauf).
- VS Code: 84 teilweise (acht statt vier Blicke, bevor der alte Stand als „live“ gilt), 89 (`repoSlug` gelöscht, Test auf `repoKey`).
- iPhone: 117 (Vercel und Render werden gleichzeitig gelesen), 121 (die erste bekannte Sprache der Liste, nicht die erste),
  101 (Phasen-Symbole mit VoiceOver-Text), 102 (die Laufzeit in der Dynamic Island wird skaliert statt abgeschnitten), 103 (doppelte
  Modifier in `BigNumber`), 106 (ein Widget mit fehlgeschlagenem Build steigt im Smart Stack auf), 124 teilweise (Sprachliste, altes
  Snapshot-Format).

## Offen, mit Grund

- 15 Streamable HTTP: nur lokal mit Token wäre ein eigener Server-Zweig mit eigener Auth und eigenen Tests; ohne einen Entwurf für die
  Absicherung (Origin-Prüfung, Token-Rotation) lasse ich es weg, statt einen halben Fernzugang zu liefern.
- 38 (`wait -n` im Digest): `wait -n` fehlt in bash 3.2 (macOS-Standard), die Skripte laufen dort.
- 40, 41, 47, 48, 54, 55, 56, 59, 64: Docker-Digest, Fingerabdruck des Schlüsselbunds und Action-SHAs brauchen einen Netzabruf, den ich
  nicht belegen kann; ein ungeprüfter Hash wäre schlechter als keiner.
- 50: die Wartephase teilt sich schon eine Frist; die Builds laufen ohnehin gleichzeitig, das Nacheinander-Zuschauen kostet keine Zeit.
- 57, 63, 65, 66: Änderungen an `ci.yml` und `dependabot.yml` lassen sich nur in der CI prüfen (actionlint prüft nur die Syntax).
- 86 (Git-Erweiterung statt `git remote`), 90, 92, 93: eigener Umfang mit der VS-Code- und Raycast-API, hier nicht prüfbar.
- 95 (iPhone: Netlify, Cloudflare, DigitalOcean …): je ein API-Client, ein Schlüssel im Schlüsselbund und die Kopplung über
  `shared/PhoneLink.swift`; ohne Konten bei den Anbietern nur gegen erfundene Antworten prüfbar, und die Kopplung verändert das
  QR-Format. Nicht ohne Entwurf.
- 96, 97 (iPhone: Fenster und Freigaben, Journal): das iPhone liest `window.json` und das Journal des Macs nicht; beides braucht einen
  Weg vom Mac zum iPhone (Schlüsselbund-Sync oder Datei), der noch nicht existiert.
- 98, 100, 131 (Live-Activity-Push): APNs-Schlüssel und ein Server.
- 104, 105, 107–109, 112, 118, 122, 125, 126: App-Intents und Widget-Konfiguration brauchen Xcode-UI-Tests; `timeSensitive` braucht
  die Entitlement-Änderung der App; 118 ändert das Abbruchverhalten des Hintergrundlaufs.
- 144, 145 (Telegram-Bot und `bot-only.sh`): nicht erreicht.
