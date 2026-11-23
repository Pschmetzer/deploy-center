# Claude in Deploy Center

Die deutsche Fassung von [CLAUDE-IN-APP.md](CLAUDE-IN-APP.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Deploy Center kann Claude drei Fragen zu deinen Deploys stellen, mit **deinem eigenen Anthropic-API-Key**.
Das ist freiwillig und standardmäßig aus.

| Frage | Wo | Was gesendet wird |
|---|---|---|
| **Diesen Fehler erklären** | Detailfenster und Build-Log, wenn der letzte Build fehlgeschlagen ist: *Claude fragen* | der Teil des Build-Logs rund um den ersten Fehler, maskiert |
| **Release-Notes für Menschen** (EN/DE) | Detailfenster, wenn Commits warten: *Claude fragen* | die Titel der wartenden Commits und PRs (keine Autoren, keine IDs) |
| **Kann das live gehen?** | Detailfenster, wenn Commits warten: *Claude fragen* | die Diff-Statistik, die riskanten Dateinamen (Migrationen, env-Dateien, Lockfiles, Build-Konfiguration, Workflows), die Commit-Titel, ob Auto-Deploy an ist |

*Diesen Fehler erklären* bietet auch **Mit Claude beheben** an, derselbe Knopf wie in der Zeile: Der fehlgeschlagene
Build geht an deine [Autofix](AUTOFIX.md)-Routine (`deploys autofix --only <platform> <project>`),
unter den üblichen Obergrenzen. Ist Autofix nicht eingerichtet, bietet er stattdessen die Einrichtung an.

## Einschalten

Einstellungen → Claude → **Claude in der App** → *Claude mit meinem eigenen API-Schlüssel fragen*. Füge einen Key von
[console.anthropic.com](https://console.anthropic.com/settings/keys) ein, **Speichern**, dann **Prüfen**
(es fragt mit dem Key das Modell ab; das kostet nichts). Das Menü *Claude fragen* erscheint nur,
wenn der Schalter an ist und ein Key gespeichert ist.

- **Modell:** Standard ist Claude Opus 5.5; Claude Sonnet 5.5 und Claude Haiku 5.5 sind billiger.
- **Monatslimit:** Standard sind 300.000 Tokens. Es wird vor jeder Anfrage geprüft; ist es erreicht,
  wird nichts mehr gesendet, bis der nächste Monat beginnt oder du es erhöhst. Die Zählung liegt auf diesem Mac
  (`~/.config/deploys/ai-usage.json`); für die Abrechnung bleibt die Anthropic Console maßgeblich.

## Datenschutz

- Kein Server von uns und keine Telemetrie: Die App (über `deploys`) spricht direkt mit `api.anthropic.com`.
- Der Key liegt im macOS-Schlüsselbund (Eintrag `deploy-center-anthropic`), geschrieben von `deploys ai set-key`
  über stdin. Er wird nie ausgegeben und nie als Befehlsargument übergeben.
- Der Key wird in dieser Reihenfolge genommen: `DEPLOYS_ANTHROPIC_API_KEY`, dann `ANTHROPIC_API_KEY`, dann der
  Schlüsselbund. `ANTHROPIC_API_KEY` ist oft für ein anderes Konto gesetzt (Claude Code, ein SDK), und dann
  zahlt dieses Konto. `deploys ai status` sagt das (`envHidesKeychain: true`), und Einstellungen → Claude →
  Claude in der App warnt. Setze `DEPLOYS_ANTHROPIC_API_KEY` oder hebe `ANTHROPIC_API_KEY` auf, um den
  Key zu nutzen, den du gespeichert hast.
- Alles, was gesendet wird, läuft zuerst durch denselben Maskierer wie bei Autofix: API-Keys und Tokens (`sk-…`,
  `ghp_…`, `github_pat_…`, `xox…`, `AKIA…`, `rnd_…`, JWTs), Werte der Art `token=` / `password:`,
  Passwörter in URLs und E-Mail-Adressen. Eine Hilfe, keine Garantie: Lies [SECURITY.md](../SECURITY.md).
- Die Prompts sagen Claude, Logs und Commit-Titel als Daten zu behandeln, nie als Anweisungen.

## Kommandozeile

Die App führt diese aus; du kannst es auch.

```bash
pbpaste | deploys ai set-key          # store the key (or set DEPLOYS_ANTHROPIC_API_KEY)
deploys ai verify                     # the key works and the model is available
deploys ai explain my-project         # why the newest build failed, and the likely fix
deploys ai notes my-project --lang de # plain release notes, English (default) or German
deploys ai ship my-project            # Risk: low, medium or high, and what to check
deploys ai model claude-sonnet-5-5    # claude-opus-5-5 (default), claude-sonnet-5-5, claude-haiku-5-5
deploys ai cap 500000                 # tokens per month
deploys ai status                     # key set (never the key) and from where, model, cap, used this month
deploys ai forget-key
```

Hänge `--json` an `explain`, `notes` und `ship`, um `{text, model, tokens, used, cap}` zu bekommen.

Die Anfrage geht an die Messages API (`anthropic-version: 2026-10-21`) mit niedrigem Effort. Bei Opus und Sonnet
ist der serverseitige Fallback an (`fallbacks: "default"`): Lehnt ein Sicherheitsklassifikator ab, antwortet die API
im selben Aufruf mit einem Fallback-Modell. Eine Ablehnung, die bleibt, wird als solche gemeldet.

## „What this ships“ bei jedem Pull Request

[examples/claude-pr-ship-check.yml](../examples/claude-pr-ship-check.yml) ist ein GitHub-Workflow für
das Repo deiner App. Bei jedem Pull Request:

1. führt er `deploys changed --json` über [die Deploy-Center-Action](../integrations/action/) aus
   (nur Bericht, deployt nie),
2. listet er jedes Projekt auf, das aus diesem Repo deployt, mit seiner Auto-Deploy-Einstellung
   (`deploys list --json`, jede eingerichtete Plattform) und was schon darauf wartet,
3. führt er Anthropics [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action)
   (`anthropics/claude-code-action` v1, auf einen Commit festgelegt) mit dieser Liste im Prompt aus; Claude liest den PR-Diff und
   postet einen Kommentar, *What this ships*: die betroffenen Projekte, eine Risikostufe und ob
   Auto-Deploy aus ist (dann geht beim Merge nichts live, bis jemand deployt).

Claude darf nur `gh pr diff`, `gh pr view` und `gh pr comment` ausführen. Es braucht die
Secrets `ANTHROPIC_API_KEY` und `VERCEL_TOKEN` und/oder `RENDER_API_KEY` sowie die Workflow-Berechtigungen
`contents: read`, `pull-requests: write`, `id-token: write`. Pull Requests aus Forks
bekommen keine Secrets und werden übersprungen; stelle ihn nicht auf `pull_request_target` um.

## Weitere Wege, Claude mit Deploy Center zu nutzen

- **Für Claude kopieren** im Build-Log: ein fertiger Prompt mit dem maskierten Log, für jeden Claude-Chat.
- [Autofix](AUTOFIX.md): Ein fehlgeschlagener Build geht an eine Claude-Code-Routine, die einen Fix-PR öffnet.
- Einstellungen → Claude verbindet Claude Desktop und Claude Code (den [MCP-Server](../integrations/mcp/)
  und das [Claude-Code-Plugin](../integrations/claude-code/)).
