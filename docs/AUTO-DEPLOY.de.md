# Auto-Deploy ausschalten und wieder einschalten

Die deutsche Fassung von [AUTO-DEPLOY.md](AUTO-DEPLOY.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

## Was sich ändert

| | Vercel | Render |
|---|---|---|
| Was Deploy Center tut | Entfernt die Git-Verbindung des Projekts. Vorher schreibt es Repo und Produktions-Branch in `~/.config/deploys/vercel-repos.json`. | Setzt Auto-Deploy des Dienstes auf *Off*. Der Dienst bleibt mit seinem Repo verbunden. |
| Push auf den Produktions-Branch | Vorher: ein Produktions-Build. Nachher: nichts. | Vorher: ein Deploy. Nachher: nichts. |
| Push auf einen anderen Branch oder ein PR | Vorher: ein Preview-Build. Nachher: nichts, da es keine Git-Verbindung gibt. | Deploy Center ändert das nicht. |
| Deployen | `deploys vercel deploy` oder die App (neuester Commit). **Redeploy** im Dashboard baut den Commit eines vorhandenen Deployments noch einmal. | `deploys render deploy`, die App oder **Manual Deploy** im Dashboard. |
| Was live geht | Der neueste Commit des gemerkten Branches auf GitHub. | Der neueste Commit des Branches des Dienstes. |
| GitHub-Workflows, Deploy-Hooks | GitHub-Workflows, die deployen, laufen weiter; `deploys triggers` listet sie. Vercel-Deploy-Hooks liegen in den Git-Einstellungen: im Dashboard prüfen. | Laufen weiter. Ein Blueprint mit Auto-Sync kann Auto-Deploy wieder einschalten (siehe unten). |
| Anzeige | Die Zeile sagt nicht mehr **deployt bei jedem Push**; `deploys vercel list` zeigt `manual`. | Die Zeile sagt nicht mehr **deployt bei jedem Push**; `deploys render list` zeigt `off`. |

Render: Stammen deine Dienste aus einem Blueprint mit Auto-Sync, trage `autoDeployTrigger: off` bei jedem Dienst in `render.yaml` ein. Sonst kann der nächste Sync es zurücksetzen.

## Zurück zu Auto-Deploy

Dauerhaft, je Projekt oder für alle:

```bash
deploys vercel autodeploy-on my-project   # oder --all: verbindet Git wieder aus vercel-repos.json
deploys render autodeploy-on my-service   # oder --all: Auto-Deploy „On Commit“
```

Für ein paar Stunden (der [Guard](GUARD.md) schaltet es danach wieder aus):

```bash
deploys autodeploy allow vercel my-project 4
```

Vercel braucht das Repo in `~/.config/deploys/vercel-repos.json` (jeder Eintrag hat `org`, `repo` und `ref`, den Produktions-Branch). Prüfe danach, dass Project → Settings → Git → Production Branch zu `ref` passt. Im Dashboard: Project → Settings → Git → Repository wieder verbinden.

**Render** im Dashboard: Service → Settings → Build & Deploy → Auto-Deploy → *On Commit*.

Die App zeigt die Zeile dann wieder als **deployt bei jedem Push**, und die Menüleiste zählt sie bei „Auto-Deploy ist noch an für … Projekte“. Ist der [Guard](GUARD.md) an, schaltet er es innerhalb von 30 Minuten wieder aus, außer eine Freigabe deckt es ab.

Bevor du Deploy Center deinstallierst, behalte `~/.config/deploys/vercel-repos.json`, bis jedes Vercel-Projekt wieder verbunden ist. Für ein Projekt, das du mit Deploy Center getrennt hast, ist es die einzige Aufzeichnung, woher es deployt hat.
