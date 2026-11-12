# Ersparnis: simulate und ledger

Deutsche Fassung von [SAVINGS.md](SAVINGS.md).

Zwei Befehle, zwei Fragen:

- `deploys simulate [--days 30]`: *Was kostet Auto-Deploy im Monat, verglichen mit einem Deploy pro Tag?* Geht, bevor du etwas abschaltest.
- `deploys ledger`: *Was hat das Abschalten bisher gespart?* Zählt ab dem Tag, an dem Auto-Deploy aus ging.

Beide brauchen `gh` (angemeldet), weil sie Pushes auf GitHub zählen. Mit `--json` kommt die Antwort für Maschinen. In der App: der Simulator (ein Banner, solange nichts abgeschaltet ist, und Einstellungen → Kosten → Ersparnis) und das Ledger („≈ $X gespart seit …“, pro Projekt).

Jede Zahl ist eine Schätzung und trägt „≈“. Das JSON sagt, wie sie entstand (`method`).

## So wird geschätzt

**Pushes auf den Deploy-Branch × durchschnittlicher Build des Projekts**

1. **Pushes**: aus GitHubs Aktivitätsliste des Deploy-Branches (`repos/{repo}/activity`: `push`, `force_push`, `pr_merge`, `merge_queue_merge`). Ist die nicht lesbar, stehen die Commits auf dem Branch dafür. Ein Push kann mehrere Commits tragen, die Zahl ist dann eine obere Grenze. `basis` sagt, was genommen wurde.
2. **Durchschnittlicher Build**: die mittlere Dauer der letzten 20 fertigen Builds (Vercel: `READY`; Render: `live` oder `deactivated`). Fehlgeschlagene und abgebrochene Builds werden nicht gemessen.
3. **Preis pro Build**, der erste bekannte:
   1. Vercel-Abrechnung (`deploys costs`, letzte 7 Tage): abgerechnete Build-Dollar / Builds des Projekts (`vercel-billing`).
   2. Der Preis pro Build-Minute im Team (abgerechnete Build-Dollar / abgerechnete Build-Minuten über alle Vercel-Projekte mit Abrechnung) × durchschnittlicher Build (`vercel-team-rate`).
   3. Ein selbst gesetzter Preis (`rate-setting`): `DEPLOYS_VERCEL_USD_PER_MIN` für eine Vercel-Build-Minute, `DEPLOYS_RENDER_USD_PER_MIN` für eine Render-Pipeline-Minute.

   Render hat keine Abrechnungs-API. Ohne `DEPLOYS_RENDER_USD_PER_MIN` zeigt Render nur Pipeline-Minuten, die Dollar bleiben `null` („?“).

**simulate**: jeder Push im Zeitraum zählt als ein Build („Auto-Deploy“). „Einmal am Tag“ zählt einen Build an jedem Tag mit Push. Beides wird vom Zeitraum (`--days`, 1 bis 90) auf 30 Tage hochgerechnet.

**ledger**: ab dem Tag, an dem Auto-Deploy aus ging (pro Projekt), zählt jeder Push, dessen Commit nie gebaut wurde, als gesparter Build. Projekte, deren Auto-Deploy hier nie abgeschaltet wurde, fehlen.

## Beispiele

```bash
deploys simulate
```

```
Estimate over the last 30 days, per month:
  web (vercel): 6 pushes; auto-deploy ≈ $1.2, 18 build minutes; once a day ≈ $0.4
  api (render): 4 pushes; auto-deploy ≈ ?, 20 pipeline minutes; once a day ≈ ?
Auto-deploy would cost ≈ $1.2 a month; deploying once a day ≈ $0.4.
```

```bash
DEPLOYS_RENDER_USD_PER_MIN=0.01 deploys simulate --days 14
deploys ledger
```

```
Since 2026-01-20: ≈ $0.8 saved, 6 builds skipped (12 Vercel build minutes, 10 Render pipeline minutes).
  web (vercel), off since 2026-01-20: 4 of 5 pushes not built, ≈ $0.8, 12 build minutes
  api (render), off since 2026-01-25: 2 of 3 pushes not built, ≈ ?, 10 pipeline minutes
```

```bash
deploys ledger --json | jq '.total.usd'
```

Die CLI antwortet auf Englisch.

## JSON

Beide: `estimate` (immer `true`), `kind` (`simulate` oder `ledger`), `currency` (`USD`), `generatedAt`, `method`, `projects`, `total`.

Pro Projekt, beide:

| Feld | Bedeutung |
|---|---|
| `platform`, `name` | `vercel` oder `render`, und das Projekt |
| `unit` | `build minutes` (Vercel) oder `pipeline minutes` (Render) |
| `basis` | `pushes` oder `commits` (obere Grenze); `null`, wenn GitHub nicht lesbar war |
| `problem` | warum eine Zahl fehlt, sonst `null` |
| `pushes` | gezählte Pushes im Zeitraum |
| `avgBuildMinutes`, `buildsMeasured` | der durchschnittliche Build und aus wie vielen Builds (höchstens 20) |
| `usdPerBuild`, `priceSource` | Preis eines Builds, und `vercel-billing`, `vercel-team-rate`, `rate-setting` oder `null` |

simulate (oben `days`, `teamUsdPerBuildMinute`):

| Feld | Bedeutung |
|---|---|
| `auto` | Auto-Deploy ist jetzt an |
| `activeDays`, `pushesPerDay` | Tage mit Push, Pushes pro Tag |
| `autoMonth`, `dailyMonth`, `savingMonth` | `{builds, minutes, usd}` pro Monat: Auto-Deploy, einmal am Tag, die Differenz |
| `total.*Month` | `{usd, vercelMinutes, renderMinutes, builds}` über alle Projekte |
| `total.usdComplete` | `false`, wenn ein Projekt mit Pushes keinen Preis hat; `usd` ist dann zu niedrig |

ledger (oben `since`, `days` seit dem ersten abgeschalteten Projekt):

| Feld | Bedeutung |
|---|---|
| `offAt`, `offDay` | wann Auto-Deploy aus ging |
| `builds`, `skipped` | Builds seitdem, und Pushes, die nie gebaut wurden |
| `savedMinutes`, `savedUsd`, `builtUsd` | die gesparten Builds in Minuten und Dollar, und was die gelaufenen Builds kosteten |
| `skippedPushes` | die letzten 20 gesparten Pushes, `{day, sha}` |
| `total` | `skipped`, `pushes`, `builds`, `usd`, `builtUsd`, `vercelMinutes`, `renderMinutes`, `usdComplete` |

## Grenzen

- Eine Schätzung, keine Rechnung. Es zählt die Rechnung von Vercel oder Render.
- Nur Vercel und Render. Die Zahlen kommen aus der Liste vergangener Deploys je Host und einem Preis pro Build-Minute, und angebunden sind bisher nur diese beiden. Die Opt-in-Hosts (Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean, Coolify, Deploy-Hooks) erscheinen in `simulate` und `ledger` nicht, auch nicht als Anzahl; einen Termin dafür gibt es noch nicht. Bis dahin zeigen ihre eigenen Dashboards die Build-Minuten.
- Jeder Build kostet den Durchschnitt. Build-Caches, größere Maschinen und Inklusiv-Minuten fehlen.
- Die Vercel-Abrechnung deckt nur die letzten 7 Tage ab. Ein Projekt ohne abgerechnete Builds dort nimmt den Team-Preis.
- Die Commit-Ersatzzählung zählt zu viel, wenn ein Push mehrere Commits trägt.
- Ein Deploy, das ein Hook oder Workflow startet, zählt als gebaut; das Ledger zählt diesen Push dann nicht als gespart.
- Ohne `gh`, oder ohne bekanntes Repo und Branch, hat ein Projekt keine Zahlen (`problem` sagt warum).

## Warum steht da ≈ 0 $?

- **Nichts wurde übersprungen.** Das Ledger zählt einen Push nur dann als gespart, wenn sein Commit nach dem Abschalten von Auto-Deploy nie gebaut wurde. Hast du jeden Push deployt, oder hat ein Hook oder Workflow ihn gebaut, ist nichts gespart.
- **Der Commit wurde als Preview gebaut.** Bei Vercel zählt jedes Deployment des Projekts, auch Previews. Bei einem Fast-Forward-Merge ist der Commit auf dem Deploy-Branch derselbe, den schon eine Preview gebaut hat; der Push zählt dann als gebaut.
- **Keine Pushes im Zeitraum.** `simulate` zählt die letzten `--days` (Vorgabe 30), `ledger` erst ab dem Tag, an dem Auto-Deploy hier abgeschaltet wurde. Projekte, deren Auto-Deploy nie mit Deploy Center abgeschaltet wurde, fehlen im Ledger ganz.
- **Billige Builds.** Dollar werden auf Cent gerundet. Zeigt die Vercel-Abrechnung der letzten 7 Tage 0 $ für die Builds des Projekts, kostet ein Build 0 $.
- **„?“ ist nicht 0.** Ohne bekannten Durchschnitts-Build (kein fertiger Build unter den letzten 100) oder ohne Preis (Render ohne `DEPLOYS_RENDER_USD_PER_MIN`) ist die Zahl unbekannt und zeigt „?“. Die Summe hat dann `usdComplete: false`.

Umgekehrt: Gelesen werden nur die letzten 100 Deployments eines Projekts. Bei einem Projekt mit vielen Deploys kann ein älterer, gebauter Push ungebaut aussehen und zählt dann als gespart.
