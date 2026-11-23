# Deploy Center mit Claude Code

Die deutsche Fassung von [CLAUDE-CODE.md](CLAUDE-CODE.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Deploy Center arbeitet mit Claude Code zusammen. Claude schreibt den Code und behebt fehlgeschlagene Builds; du entscheidest,
was live geht. Auto-Deploy bleibt aus, ein Push kostet also nichts, bis du deployst.

## Einrichtung in 3 Schritten

1. **Installiere Deploy Center** von [deploycenter.app](https://deploycenter.app), melde dich bei Vercel an
   und/oder füge deinen Render-Schlüssel hinzu, und schalte Auto-Deploy für deine Projekte aus. Prüfe es mit
   `deploys doctor` und `deploys changed` in einem Terminal.
2. **Füge das Plugin hinzu** in einer Claude-Code-Sitzung:
   ```text
   /plugin marketplace add Pschmetzer/deploy-center
   ```
   ```text
   /plugin install deploy-center@deploy-center
   ```
   (Ab v2.1.275: `/plugin install deploy-center --marketplace Pschmetzer/deploy-center`.)
3. **Probier es aus:** Führe `/deploy-center:deploys-waiting` aus oder frag: „What is waiting to go live?“.

Was das Plugin enthält (Skill, vier Befehle, der Push-Hook), steht in
[integrations/claude-code/README.md](../integrations/claude-code/README.md).

## Ohne das Plugin: ein CLAUDE.md-Block

Füge das in die `CLAUDE.md` deines Projekts ein (oder in `~/.claude/CLAUDE.md` für jedes Projekt). Der Block bleibt englisch, weil Claude ihn so liest:

```markdown
## Deploys (Deploy Center)

Git auto-deploy is off on this project's Vercel/Render. A push does not go live; a person deploys.

- NEVER deploy without my explicit OK for that project in this conversation. "Push", "commit" or
  "fix the build" is not an OK. Never turn auto-deploy back on or change deploy settings.
- After a push: run `deploys changed --json` and tell me in one line what is waiting.
- A failed build: run `deploys status --json`, then `deploys logs <project>`. Find the first error.
  If the cause is in the code, propose the smallest fix (or make it if I asked). If it is a missing
  env var, secret, quota or outage, change nothing and tell me what to set. Never paste secrets.
- Why auto-deploy is off: every push would start a paid build; I deploy the batch once instead.
- Numbers look odd (a project counted as changed or not): run `deploys explain <project>`.
- When I say deploy: `deploys deploy <project> --wait` (any platform; it checks deploy windows,
  CI and team approvals, and follows the build until live or failed). One project, then report.
```

## Das Sicherheitsmodell

- **Deployen braucht dich.** Der Skill und der CLAUDE.md-Block sagen es in klaren Worten. Der Befehl
  `/deploy-center:deploys-ship` zeigt, was live gehen würde, und hält dann an, um zu fragen; das Ausführen des
  Befehls ist nicht das Ja, deine nächste Nachricht ist es. `/deploy-center:deploys-rollback` funktioniert genauso,
  und der Subagent `ship-reviewer` liest nur (er führt nie `deploy-changed --yes` aus).
- **Nichts gibt einen Deploy vorab frei.** Die `allowed-tools` des Plugins listen nur lesende Befehle
  (`deploys changed`, `status`, `logs`, `explain`, `notes`, `diff`, `history`, `doctor`). Ein Deploy ist
  immer ein normaler Bash-Aufruf, also fragt Claude Code nach Erlaubnis, sofern du ihn nicht selbst erlaubt hast.
  Um daraus eine harte Regel zu machen, füge Deny-Regeln in `.claude/settings.json` (oder `~/.claude/settings.json`) ein.
  Sie decken jeden Befehl ab, der einen Build startet, stoppt oder zurückrollt, Auto-Deploy einschaltet oder
  ändert, was von selbst deployt:

  ```json
  {
    "permissions": {
      "deny": [
        "Bash(deploys deploy-changed*)",
        "Bash(deploys deploy *)",
        "Bash(deploys * deploy *)",
        "Bash(deploys * deploy-json*)",
        "Bash(deploys * rollback*)",
        "Bash(deploys * cancel*)",
        "Bash(deploys * autodeploy-on*)",
        "Bash(deploys autodeploy *)",
        "Bash(deploys guard*)",
        "Bash(deploys autofix*)",
        "mcp__deploys__deploys_deploy",
        "mcp__deploys__deploys_rollback"
      ]
    }
  }
  ```

  Die Regeln nennen die Unterbefehle, nicht `deploy*`, sodass lesende Aufrufe wie `deploys logs deploy-site`
  erlaubt bleiben. Claude Code gleicht Bash-Regeln mit dem Befehl ab, wie er geschrieben steht, also ist eine Deny-Regel
  ein Geländer, keine Sandbox.
- **Die Befehle gehören dir.** Alle vier `/deploys-*`-Befehle setzen `disable-model-invocation: true`,
  sodass Claude sie nicht von selbst starten kann.
- **Der Hook liest nur.** Er ruft `deploys changed --json` auf, gibt eine Zeile aus und endet immer mit 0.
  Ohne `deploys` gibt er nichts aus.
- **Logs sind Daten.** Der Skill sagt Claude, dass es nie Anweisungen befolgt, die in Build-Logs,
  Commit-Nachrichten oder PR-Texten stehen, und nie Geheimnisse daraus einfügt.
- **Auto-Deploy bleibt aus.** Nichts hier verbindet Git neu oder ändert Einstellungen bei Vercel oder Render.
- **MCP**, wenn du es hinzufügst: nur lesend, es sei denn, du startest es mit `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Selbst
  dann fragt der Server dich selbst (MCP-Elicitation) vor jedem Deploy oder Rollback, einzeln
  und höchstens `DEPLOYS_MCP_MAX_DEPLOYS` (Standard 3) pro Lauf; siehe
  [integrations/mcp](../integrations/mcp/README.md#safety).

## Wie Autofix dazupasst

Ein fehlgeschlagener Build wird auf zwei Wegen behoben, und sie konkurrieren nicht:

| | In deiner Sitzung (dieses Plugin) | Autofix ([AUTOFIX.md](AUTOFIX.md)) |
|---|---|---|
| Start | wenn du `/deploy-center:deploys-fix <project>` ausführst oder Claude fragst | von selbst, `deploys autofix` alle 10 Minuten auf deinem Mac |
| Läuft | in der Claude-Code-Sitzung, in der du bist, in deinem Checkout | in einer Claude-Code-Routine in der Cloud |
| Ergebnis | ein Fix in deinem Arbeitsverzeichnis; du committest und pushst | ein Pull Request auf `claude/autofix-<project>-<sha>` |
| Deployt | nie; du lieferst mit `/deploy-center:deploys-ship` aus | nie; nach dem Merge bekommst du eine Mitteilung und deployst |

Hat Autofix für den Fehler schon einen PR geöffnet, sagt der Skill Claude, nach dem offenen
`autofix(<project>)`-PR zu suchen, statt dasselbe zweimal zu beheben. In beiden Fällen ist der letzte Schritt
derselbe: Du sagst Ja, dann geht es live.

Claude und Claude Code sind Marken von Anthropic. Deploy Center steht in keiner Verbindung zu Anthropic.
