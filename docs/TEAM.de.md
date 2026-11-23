# Team-Modus

Die deutsche Fassung von [TEAM.md](TEAM.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Dieselben Deploy-Regeln auf dem Mac jedes Teammitglieds, ohne Server. Deploy Center hat weiterhin kein Backend:
Die gemeinsamen Einstellungen sind eine Datei in deinem Repo, Freigaben sind GitHub-Reviews oder -Labels, und jeder Mac
liest beides mit seinem eigenen `gh`-Login.

Drei Teile:

1. **Gemeinsame Konfiguration**: `deploy-center.json` im Stammverzeichnis eines Repos.
2. **Beobachter-Modus**: ein Mac (oder ein CI-Job), der nur ansehen, aber nie deployen darf.
3. **Zwei-Personen-Regel**: optional, pro Projekt. Ein Produktions-Deploy braucht die Freigabe einer anderen Person.

> Der Team-Modus hält ein Team konsistent. Er erzwingt nichts. Wer ein Vercel- oder Render-Login hat,
> kann weiterhin aus dem Dashboard deployen. Zum Erzwingen von Regeln nimmst du die Rollen der Plattformen und
> den Branch-Schutz von GitHub. Deploy Center macht den vereinbarten Weg zum einfachen Weg und hält
> jede Ausnahme fest.

## 1. Gemeinsame Konfiguration: `deploy-center.json`

Leg sie ins Stammverzeichnis des Repos, auf den Standard-Branch. `.deploy-center.json` geht auch.
Das Schema ist [`deploy-center.schema.json`](deploy-center.schema.json), auch erreichbar unter `https://deploycenter.app/schema/deploy-center.schema.json` (eine stabile Adresse mit dem richtigen Content-Type). Verweise mit `$schema` darauf, dann
prüft dein Editor die Datei beim Tippen.

```json
{
  "$schema": "https://deploycenter.app/schema/deploy-center.schema.json",
  "version": 1,
  "approvals": 1,
  "health": "/api/health",
  "window": { "days": ["mon", "tue", "wed", "thu"], "from": "09:00", "to": "16:00", "tz": "Europe/Berlin" },
  "projects": {
    "shop-web": { "platform": "vercel", "branch": "main", "health": "/healthz" },
    "shop-api": { "platform": "render", "approvals": 2 },
    "shop-docs": { "platform": "vercel", "approvals": 0 }
  },
  "ignored": ["shop-playground"],
  "groups": { "shop": ["shop-api", "shop-web"] },
  "observers": ["a-github-login"]
}
```

| Schlüssel | Was er bewirkt |
|---|---|
| `approvals`, `health`, `window` at the top | Standardwerte für jedes Projekt, das aus diesem Repo deployt |
| `projects.<name>` | Ein Vercel-Projekt oder ein Render-Dienst: `platform`, `repo` (Standard: dieses Repo), `branch`, `health`, `window`, `approvals`, `ignored` |
| `ignored` | Wird bei `deploys changed` und `deploy-changed` ausgelassen |
| `groups.<name>` | Projekte, die zusammen deployt werden, in Reihenfolge. `deploys deploy shop` startet `shop-web`, sobald `shop-api` live ist |
| `observers` | GitHub-Logins, die ansehen, aber nicht deployen dürfen |

`health` und `window` werden hier gespeichert und angezeigt. Die Prüfungen für sicheres Deployen nutzen sie (Health-Check
nach einem Deploy, Deploy-Fenster). Diese Datei legt nur fest, was sie sind.

### Welche Repos gelesen werden

`deploys` liest die Datei im Repo jedes Projekts:

- jedes Repo in `~/.config/deploys/vercel-repos.json` (gemerkt, als Auto-Deploy ausgeschaltet wurde),
- das Repo eines Render-Dienstes, wenn er deployt wird,
- jedes Repo, das du hinzufügst: `deploys team add owner/repo`. Ein neues Teammitglied fängt hier an. Die Datei ordnet
  die Projekte des Teams ihren Repos zu, damit es deployen kann, ohne vorher etwas zu trennen.

Jede Datei wird mit `gh api repos/<repo>/contents/deploy-center.json` gelesen und zehn Minuten lang
in `~/.config/deploys/team-cache/` gehalten. Ist GitHub nicht erreichbar, wird die gespeicherte Kopie benutzt und
als veraltet markiert. Jetzt neu lesen kannst du mit `deploys team refresh` oder `deploys config --refresh` (oder `DEPLOYS_TEAM_REFRESH=1` bei jedem Befehl); das Alter des Caches ist `DEPLOYS_TEAM_TTL` Sekunden (Standard 600).

### Reihenfolge beim Zusammenführen

Das Unterste zuerst. Eine spätere Ebene gewinnt:

1. was die Plattform sagt (Repo und Branch eines Render-Dienstes)
2. die Standardwerte der obersten Ebene der Repo-Datei
3. der Eintrag der Repo-Datei für das Projekt (`projects.<name>`, `ignored`)
4. dieser Mac: `vercel-repos.json` (Repo, Branch), `ignored.json`, `window.json`, dann
   `overrides.json` (gleiche Form wie die Repo-Datei, nur für diesen Mac)

Zwei Ausnahmen. Dieser Mac kann sie nur **verschärfen**:

- `approvals`: Eine lokale Zahl zählt nur, wenn sie höher ist. Um an einer fehlenden Freigabe vorbeizukommen, nimm
  `--force "reason"`, was ins Journal geschrieben wird.
- `observers`: Alle Listen werden zusammengeführt. Ein Mac kann Namen hinzufügen, aber nicht entfernen.

`deploys ignore <p> --undo` bei einem Projekt, das die Team-Datei ignoriert, schreibt `"ignored": false` in
`overrides.json`, sodass dieser Mac es wieder mitzählt.

### Das Ergebnis ansehen

```bash
deploys config
```

```bash
deploys config --json
```

Jeder Wert wird als `{"value": …, "from": …}` angezeigt. `from` ist `owner/repo:deploy-center.json`,
`vercel-repos.json`, `ignored.json`, `window.json`, `overrides.json`, `platform` oder `default`.
Das JSON listet außerdem die gefundenen Dateien (`sources`, mit `stale` und `error`), die Gruppen, die
Beobachter, wer du auf GitHub bist (`me`) und ob dieser Mac ein Beobachter ist (`readonly`).

## 2. Beobachter-Modus

Eines davon macht einen Mac (oder einen CI-Job) zum Beobachter:

- die Umgebungsvariable `DEPLOYS_READONLY=1`,
- die Datei `~/.config/deploys/readonly` (`deploys readonly on` / `off`; der Schalter der App unter
  **Einstellungen → Team** macht dasselbe),
- dein GitHub-Login steht in `observers` in einer gemeinsamen Datei.

Ein Beobachter darf jeden Befehl nutzen, der nur liest. Befehle, die etwas bei Vercel,
Render oder GitHub ändern, stoppen, bevor sie irgendetwas aufrufen:

`deploy`, `deploy-changed --yes`, die Verben jedes Providers, die etwas starten, stoppen oder umschalten
(`deploy`, `deploy-json`, `rollback`, `cancel`, `map`, `autodeploy-off`, `autodeploy-on`, z. B.
`vercel deploy` oder `netlify rollback`), `hook deploy` sowie `autofix` und `guard` (beide auch mit
`--only`; jeder ist mit `--dry-run` erlaubt).

```
Error: Observer mode (DEPLOYS_READONLY is set): "deploys vercel deploy" changes something and is refused. Observers can look, not deploy. To deploy from here: unset DEPLOYS_READONLY.
```

Die eigenen Einstellungen dieses Macs bleiben erlaubt: `ignore`, `team add`, `readonly`, Schlüssel und Logins.
Der Beobachter-Modus schützt die Plattformen, nicht deine Sicht auf sie. In der App sind die Deploy-Buttons
ausgeblendet, und die Fußzeile zeigt **Beobachter**.

## 3. Zwei-Personen-Regel

Setze `"approvals": 1` (oder mehr) für ein Projekt oder ein ganzes Repo. Ein Produktions-Deploy dieses Projekts
braucht dann so viele Freigaben für genau den Commit, der deployt wird, von anderen Personen als
der, die deployt. Der geprüfte Commit ist im Deploy festgenagelt, sodass ein Push, der während der Prüfung eintrifft,
nicht ohne Freigabe live geht.

Jedes davon zählt einmal pro Person:

- **Ein zustimmendes PR-Review** an einem Pull Request, zu dem der Commit gehört. Nur das neueste Review
  dieser Person zählt. Eine Zustimmung, die später auf „Changes requested“ geändert wurde, zählt nicht.
- **Das Label `deploy-approved-by:<login>`** an diesem Pull Request oder an einem offenen Issue, dessen Titel
  oder Text den Commit nennt (seine ersten 7 Zeichen). Es zählt nur, wenn `<login>` das Label selbst
  gesetzt hat; das wird aus den Ereignissen des Issues gelesen. Jeder kann ein Label mit dem Namen einer anderen Person
  anlegen, also beweist das allein nichts. Nimm das für Commits, die ohne PR kamen.

Deine eigenen Reviews und Labels zählen nie. Previews brauchen keine Freigabe.

```bash
deploys deploy shop-web
```

```
Approvals for shop-web at 3f2a9c1 (acme/shop:deploy-center.json):
  Found none. Your own reviews and labels do not count.
  Any of these counts:
    - an approving review on PR #42 (https://github.com/acme/shop/pull/42)
    - the label deploy-approved-by:<their login> on that PR, or an open issue in acme/shop that names 3f2a9c1, added by that person
  Or, deliberately: deploys deploy shop-web --force "reason" (written to the team journal)
Error: shop-web needs 1 approval(s) from someone other than you (a-login) before 3f2a9c1 goes live.
```

Dieselbe Prüfung läuft überall, wo Produktions-Deploys starten: `deploys deploy`, `deploy-changed --yes`,
`vercel deploy`, `render deploy` und die Buttons der App. Die App zeigt das Ende der Meldung;
die ganze Meldung steht in ihrem Protokoll (Einstellungen → Hilfe → Fehlerprotokoll öffnen).

### `--force`

```bash
deploys deploy shop-web --force "hotfix for the checkout outage"
```

Der Grund ist Pflicht. Er landet zusammen mit dem Commit, wer deployt hat und welche Freigaben es gab, in
`~/.config/deploys/team-journal.jsonl`. Freigegebene Deploys werden ebenfalls ins Journal geschrieben. Das Journal
siehst du mit `deploys team journal` (`--json` für die rohen Zeilen). Das Journal liegt auf diesem
Mac. Um das Team zu informieren, füge die Zeile in den PR oder deinen Kanal ein.

## Gruppen

```bash
deploys deploy shop
```

Das startet die Mitglieder von `groups.shop` der Reihe nach. Jedes wartet, bis das vorherige live ist
(`deploys watch`). Ein Fehler stoppt den Rest. Jedes Mitglied durchläuft die Beobachter- und Freigabe-Prüfungen
für sich.

## Dateien

| Datei | Wo | Was |
|---|---|---|
| `deploy-center.json` | Repo-Stamm | gemeinsame Konfiguration |
| `overrides.json` | `~/.config/deploys/` | Überschreibungen dieses Macs, gleiche Form |
| `team-repos` | `~/.config/deploys/` | mit `deploys team add` hinzugefügte Repos |
| `readonly` | `~/.config/deploys/` | vorhanden: Beobachter-Modus |
| `team-cache/` | `~/.config/deploys/` | die gemeinsamen Dateien, zehn Minuten; dein GitHub-Login, eine Stunde |
| `team-journal.jsonl` | `~/.config/deploys/` | freigegebene und erzwungene Deploys |

`lib/team.sh` liegt neben dem `deploys`-Skript und ist in der App enthalten. Eine Kopie des
Skripts ohne sie deployt weiterhin, aber ohne die gemeinsame Konfiguration und die Zwei-Personen-Regel. Der Beobachter-Modus
über `DEPLOYS_READONLY` oder die Datei `readonly` gilt weiterhin.
