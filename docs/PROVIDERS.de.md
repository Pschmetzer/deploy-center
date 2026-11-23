# Provider: eine Plattform hinzufügen

Die deutsche Fassung von [PROVIDERS.md](PROVIDERS.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Jede Plattform, auf die `deploys` deployen kann, ist eine Datei: `providers/<p>.sh`. Heute sind das
`vercel.sh` und `render.sh` (standardmäßig an) sowie `netlify.sh`, `cloudflare.sh`, `amplify.sh`,
`digitalocean.sh`, `coolify.sh`, `fly.sh`, `railway.sh`, `heroku.sh`, `firebase.sh`, `ghpages.sh` (GitHub Pages, deployt per Workflow-Dispatch), `deno.sh` (Deno Deploy, ein Redeploy des neuesten Deployments), `koyeb.sh` (Koyeb, ein Redeploy des Dienstes) und `hook.sh` (ein allgemeiner Deploy-Hook), jeweils aus, bis sie eingeschaltet werden
(`ls providers` zeigt die Liste). `deploys` lädt beim Start jede `providers/*.sh` per `source`. Es gibt keine
Liste zu bearbeiten: die Datei hinzuzufügen fügt den Provider hinzu, und seine ID ist der Dateiname ohne `.sh`.
Die gemeinsamen Befehle (`changed`, `deploy-changed`, `status`, `watch`, `logs`, `open`, `explain`,
`doctor`, `where`, `list`) rufen nur die Funktionen unten auf. Ein neuer Provider ändert nichts außerhalb
seiner eigenen Datei, seiner Fixtures und seiner Tests.

Das Skript findet den Ordner neben sich und folgt dabei Symlinks (ein Link `~/bin/deploys` funktioniert
weiter). `DEPLOYS_DIR` überschreibt das; das Docker-Image setzt es auf `/usr/local/lib/deploys`.
`build.sh` kopiert `providers/` nach `Contents/Resources/` der App.

## An und aus

Vercel und Render sind standardmäßig an. Jeder andere Provider ist aus, bis ihn jemand einschaltet:

```bash
deploys providers enable netlify
```

```bash
deploys providers disable render
```

Die Wahl steht in `${DEPLOYS_CONFIG:-~/.config/deploys}/providers.json` als
`{"enabled":["netlify","render","vercel"]}`. Ohne diese Datei (oder mit einer, die sich nicht lesen lässt)
gelten die Standardwerte: die Provider, deren `_meta` `"defaultOn":true` sagt. Nur Vercel und Render
dürfen das sagen, darum landet ein neuer Provider in keinem Fenster, bis er eingeschaltet wird.

`list`, `changed`, `status`, `deploy-changed` und Namenssuchen berühren nur Provider, die
**an und bereit** sind. Ein Provider, der aus ist, wird nie aufgerufen und nie nach einem Schlüssel gefragt. Selbst
`deploys providers --json` fragt ihn nicht, ob er eingerichtet ist (`"ready": null`). Ein Befehl direkt
an ihn (`deploys netlify json`) wird mit der Zeile abgelehnt, die ihn einschaltet.
Wer Vercel oder Render nutzt und nie `enable` ausführt, sieht genau das, was er vorher sah.

`deploys providers --json` listet jeden Provider: sein `_meta` plus `enabled` und `ready`. Die App
zeigt Reiter nur für die eingeschalteten und einen Schalter in den Einstellungen für die anderen.

## Die Funktionen

`<p>` ist die Provider-ID. Jede Funktion ist Pflicht (`tests/providers/contract.sh` prüft, dass
es sie gibt). Wo eine Fähigkeit in `_meta` `false` ist, existiert die Funktion trotzdem und ruft
`die "<label> cannot …"` auf, ohne etwas zu senden.

| Funktion | Gibt aus / tut |
|---|---|
| `<p>_meta` | Ein JSON-Objekt: `{id, label, noun, defaultOn, keyEnv:[…], keychain, caps:{off, sha, cancel, rollback, logs, preview}}`. `noun` ist, wie ein Eintrag heißt („project“, „service“), genutzt in Hilfezeilen und Fehlern. **Eine Zeile, mit `printf` geschrieben, nicht mit jq**: `deploys` greift es mit grep ab (`meta_flag`, `meta_str`, `key_of`), auch wo jq fehlt. `contract.sh` prüft, dass es eine gültige Zeile ist. Zusätzliche Schlüssel sind erlaubt: Cloudflare und Amplify fügen `name`, `default`, `billing`, `needs`, `profileEnv` hinzu; `auth` sagt, wie sich Vercel anmeldet; `runtimeLogs` und `onDryRun` sind Flags, die `deploys` liest. |
| `<p>_ready` | Exit 0, wenn dieser Mac dafür eingerichtet ist (ein Schlüssel, eine CLI-Anmeldung). Gibt nie einen Schlüssel aus. |
| `<p>_json` | Ein JSON-Array, ein Eintrag je Projekt (Felder unten), nach Namen sortiert. Keine GitHub-Aufrufe: der Kern ergänzt die Branch-Köpfe und `changed`. |
| `<p>_has <name>` | Exit 0 und **die ID ausgeben** (was die anderen Funktionen nehmen), wenn ein Projekt dieses Namens (oder dieser ID) existiert: `lookup` nutzt diese Ausgabe, ein `_has`, das nur den Exit-Code setzt, bricht `deploys deploy p:name`. Beispiel: `netlify_has shop` gibt `site-shop` aus. Exit 1, wenn es keins gibt; Vercel endet mit 2, wenn es nicht gefragt werden konnte. |
| `<p>_off <id>\|--all` | Auto-Deploy bei Push ausschalten. Eine Zeile je Projekt ausgeben. `--all`: jedes Projekt, ein Fehler stoppt die übrigen nicht, der Exit-Code zählt sie. (Bei Amplify heißt `--all` „auch die anderen Branches“; `deploys amplify off --all` gilt je App.) |
| `<p>_deploy_json <id> [--sha S] [--preview]` | Einen Deploy starten; `{id, url, state, phase}` ausgeben (`url` kann null sein). Die Startsperre mit `start_lock "<p>-<id>"` nehmen. |
| `<p>_status <id> <deployId>` | **Eine TSV-Zeile**, `deployId<TAB>phase<TAB>rawState`, eines Deploys (zum Beispiel `d-shop-3<TAB>ready<TAB>ready`), nie JSON: `watch` liest nur die erste Zeile, und ein `{` dort lief früher endlos. Eine JSON-Variante für Menschen ist `<p>_cli_status`. |
| `<p>_latest <id> [--preview]` | Dieselbe Zeile für den neuesten Deploy (Produktion, oder mit `--preview` jedes Ziel); `none<TAB><TAB>none`, wenn es keinen gibt (kein Fehler: `watch` sagt „no deploy“). |
| `<p>_cancel <id> <deployId>` | Abbrechen; `{id, state, phase}` ausgeben (eine `message` für Menschen darf dazukommen). |
| `<p>_rollback <id>` | Produktion zurück auf den Deploy, der vorher live war; `{id, state}` ausgeben (und `phase`, `message`). Die App liest es aus `deploys <p> rollback <id>`, darum kein `_cli_rollback` mit Fließtext. |
| `<p>_logs <id> <lines> [deployId]` | Das Ende eines Build-Logs, als reiner Text. Alle drei positional: `deploys logs` übergibt für den neuesten eine leere `deployId`. Ein Provider, dessen `_meta` `"runtimeLogs":true` sagt (Render, Coolify), nimmt an dritter Stelle `--runtime` für das eigene Log der laufenden App. |
| `<p>_url <id> [--dashboard]` | Die Adresse der Seite oder die Projektseite bei der Plattform. |
| `<p>_set_key` | Einen Schlüssel von stdin lesen, ausprobieren, im Schlüsselbund als `deploy-center-<p>` speichern. |
| `<p>_doctor` | Ein JSON-Objekt mit Prüfungen (`{"<p>Key":true, …}`). Seine Felder kommen zu `deploys doctor`. `printf` bevorzugen; ein Provider, dessen Prüfungen freien Text tragen (eine Fehlerzeile), darf es für das Escaping mit `jq -n` bauen (Netlify, Cloudflare, Amplify, Coolify, DigitalOcean tun das), und dann verliert `doctor` ohne jq nur seine Felder. Provider mit `"provider"` darin liefern auch `expiresAt` (Unix-Sekunden, wann der Schlüssel endet) und `rateLimit` (`{remaining, resetAt}`, Unix-Sekunden) aus dem Aufruf, den der Doctor sowieso macht, `null`, wo die Plattform es nicht sagt (unten). |

Optionales Flag `--no-cache` bei `<p>_deploy_json`: ohne den Cache des Hosts bauen (Render `clearCache`, Netlify `clear_cache=true` am Hook, DigitalOcean `force_build`, Coolify `force=true`). Ein Host, der das nicht kann, lehnt es mit `die` ab, bevor etwas gesendet wird; nie stillschweigend ignorieren.

Optional: `<p>_where` (Zeilen für `deploys where`), `<p>_history <id> <n>` (eine Tabelle für
`deploys history`), `<p>_usage <argc> <verb>` (Hilfezeilen für Verben mit mehr Argumenten) und
`<p>_cli_<verb>` für einen Befehl, den Leute tippen und dessen Ausgabe nicht die des Vertrags ist. Zum Beispiel
behält `vercel_cli_status` das JSON, das `deploys vercel status <id>` immer ausgegeben hat, und
`<p>_cli_status` / `<p>_cli_latest` tun dasselbe für Netlify, Cloudflare, Amplify, DigitalOcean
und Coolify (ihre `_status_json` / `_latest_json`).
`vercel_on` und `render_on` (`deploys vercel|render autodeploy-on <p>|--all`) nehmen `--dry-run`:
sie lesen nur und geben aus, was sie wieder einschalten würden, je eine Zeile, oder mit `--json`
`{provider, dryRun:true, items:[{name, id, action:"on"|"skip"|"already", reason}], on, skipped}`
(FEA-110, für „alles wieder einschalten“ in docs/UNINSTALL.md). Das Flag kommt nach dem Ziel
(`autodeploy-on --all --dry-run`: `deploys` prüft das dritte Wort als Namen). Ihr `_meta` sagt
`"onDryRun":true`; ein Aufrufer prüft das zuerst, denn ein älterer Provider ignoriert `--dry-run` und
schaltet wirklich alles ein.
`<p>_cli_previews <id>` (Vercel, Netlify, Cloudflare; optional) gibt `[{id, pr, branch, url, phase, at, …}]` aus: das neueste Preview-Deployment je Pull Request, oder je Branch, wo der Host keinen PR nennt. Es liest nur, und der Host sagt nicht, ob ein PR noch offen ist.
Plattform-Extras, die nicht zum Vertrag gehören, bleiben, wo sie sind: `vercel map`,
`vercel team`, `costs`, `triggers`.

### Schlüsselende und Ratenlimit im Doctor

| Provider | `expiresAt` | `rateLimit` |
|---|---|---|
| Cloudflare | `expires_on` von `GET /user/tokens/verify` (nur ein Token mit Ablaufdatum) | `Ratelimit: "default";r=…;t=…` (`resetAt` = jetzt + t) |
| Netlify | null (die API sagt es nicht) | `X-RateLimit-Remaining`, `X-RateLimit-Reset` von `GET /user` |
| DigitalOcean | null | `ratelimit-remaining`, `ratelimit-reset` von `GET /v2/account` (je Stunde) |
| Coolify | null | `X-RateLimit-Remaining`; `resetAt` null (Laravel sendet einen Reset nur bei einem 429) |
| Amplify | null (das Ende einer SSO-Sitzung bräuchte ausgelesene Zugangsdaten) | null |
| Fly.io, Railway, Firebase Hosting, Deno Deploy, Koyeb | null | null (die API sendet beides nicht in einer Form, die hier gelesen wird) |
| Heroku | null | `RateLimit-Remaining` (`resetAt` null: Heroku sendet keinen Reset) |
| GitHub Pages | null | `resources.core` von `GET /rate_limit` (`remaining`, `reset`) |
| Vercel, Render, Hook | weggelassen: ihre Felder kommen auch auf die oberste Ebene von `deploys doctor` | weggelassen |

Die Header stammen aus dem eigenen curl-Code des Providers (`<P>_HEADERS=<file>` lässt `<p>_call` sie
behalten; `http_call` tut das nicht), und `tests/fixtures/ratelimit/` hält Header-Dateien für die Parser.

### Gemeinsame Helfer

`deploys` definiert `die`, `mtime`, `b64d`, `start_lock`, `key_of` und `CONFIG_DIR`, bevor es
die Provider lädt, und sie nutzen diese. Ein Provider, den seine eigenen Tests allein laden, definiert
einen Ersatz hinter `declare -F die >/dev/null || die() { … }`, damit die Funktion aus `deploys` immer gewinnt
(`tests/providers/contract.sh` schlägt bei einer Kopie `<p>_die`, `<p>_mtime` oder `<p>_lock` fehl).

### HTTP-Aufrufe

Ein Provider, der mit einer HTTP-API per Bearer-Schlüssel spricht, nutzt `http_call` aus `lib/http.sh`, wenn
`deploys` es geladen hat (`declare -F http_call`), mit `HTTP_AUTH` und `HTTP_FIX` als lokalen Variablen,
sonst seinen eigenen curl-Code (die Datei allein ausgeführt). Der Schlüssel geht in beiden Fällen auf stdin an curl.
Heute tun das Coolify, DigitalOcean (Aufrufe ohne Body) und Cloudflare (JSON-Aufrufe).
Sie behalten ihren eigenen Code, wo `http_call` etwas verlieren würde:

- ein Request-Body, der Env-Werte enthalten kann (DigitalOcean-Specs): `http_call` legt ihn in argv;
- ein Formular-Upload (Cloudflare `--form-string`);
- `Retry-After` und andere Antwort-Header (Render, Netlify und die Ratenlimits der Doctors);
- ein Aufruf ohne den Schlüssel (Netlify-Build-Hooks).

Das Versprechen von `<p>_call` bleibt gleich: Coolify und DigitalOcean geben 1 zurück, mit dem Grund auf
stderr (ohne `Error:`), Cloudflare beendet den Befehl. `tests/fixtures/http/stub.sh` gibt den
Provider-Tests ein `http_call` (das echte, wenn `lib/http.sh` da ist).

### Fähigkeiten und Ratenlimits

Eine Fähigkeit, die `_meta.caps` als `false` meldet, muss in `die "<host> cannot <thing>"` enden, **ohne
einen API-Aufruf** (die Vertragstests dürfen ein Stand-in-`curl` davorsetzen, das nicht aufgerufen werden darf).
`deploys providers --json` zeigt die Fähigkeiten neben jedem Provider.

Welcher Header einen Lauf zum Warten auffordert, wo ein Provider einen liest:

| Provider | Header |
| --- | --- |
| alles auf `http_call` (Aufrufe von Coolify, DigitalOcean, Cloudflare) | `Retry-After`, eine Zahl in Sekunden, höchstens 60 (`http_retry_after` in `lib/http.sh`); ein HTTP-Datum wird nicht gelesen |
| Render | `Retry-After` |
| Netlify | `Retry-After` und `X-RateLimit-Reset` |
| Cloudflare (Doctor, verbleibende Aufrufe) | `Ratelimit` (der strukturierte Header, `r=` und `t=`) |
| Coolify (Doctor, verbleibende Aufrufe) | `X-RateLimit-Remaining`, `X-RateLimit-Reset` (auch ohne `X-`) |

Sperren um die eigene Zustandsdatei eines Providers sind `file_lock` / `file_unlock` (eine mit
`set -C` angelegte Sperrdatei), nie `mkdir`: die Rust-Coreutils von Ubuntu 26.04 beantworten ein zweites `mkdir` eines
bestehenden Ordners mit Erfolg, wenn zwei gleichzeitig laufen.

### Dispatch

`deploys <p> <verb> [args]` führt `<p>_cli_<verb>` aus, wenn es existiert, sonst `<p>_<verb>` für ein Vertrags-
Verb (`-` wird zu `_`, und `autodeploy-off` ist `off`). `on` und `autodeploy-on` führen `<p>_on`
aus, wo der Provider eins hat, und `list` ist `json`, wo es kein `<p>_cli_list` gibt. Ein Verb, das er
nicht hat, wird mit der Liste seiner Befehle abgelehnt; `deploys --help` listet sie für jeden
Provider, der an ist, aus denselben Funktionen (ein eigener Befehl eines Providers, wie
`cloudflare_cli_selftest`, erscheint dort, indem er definiert wird). `<p>_setup_hint` (optional) ist der
nächste Schritt, den `deploys providers enable <p>` ausgibt, solange der Provider nicht eingerichtet ist. `<p> json` ergänzt die Branch-Köpfe und die
`changed`-Regel zu `<p>_json`. `--json` macht aus `<p> list` ein `<p> json` und aus `<p> deploy` ein
`<p> deploy-json`. Jede ältere Schreibweise funktioniert weiter (`vercel json`, `render deploy-json` und
`"$0" "$1" deploy-json` aus autofix).

### Felder von `_json`

`{name, id, auto, deployable, paused, repo, ref, domain, url, dashboardUrl, lastAt, lastState,
lastSha, lastMsg, fetchError, phase}`. Jeder Schlüssel ist vorhanden; unbekannte Werte sind `null`.

- `id`: was die anderen Funktionen nehmen. Bei Vercel ist es der Projektname; bei Render die `srv-`-ID.
- `auto`: ein Push deployt es noch. `deployable`: dieses Werkzeug kann einen Deploy starten (das Repo ist bekannt).
  Vercel: nur ein aufgeschriebenes Repo zählt. Ein Projekt, das ohne eins mit Git verbunden ist, ist `deployable:false`
  mit `repoUnknown:true` und wird nie aus seiner Live-Verbindung gebaut (`deploys vercel map` schreibt es auf).
- `repo` ist `owner/name` auf GitHub, `ref` der Branch. Beide braucht „changed“.
- `lastAt` (Unix-Sekunden), `lastSha`, `lastMsg`: was live ist. `lastState`: das eigene
  Wort der Plattform für den neuesten Versuch, roh für die Anzeige behalten.
- `fetchError`: warum der Live-Deploy nicht gelesen werden konnte. Ein Projekt mit einem wird nie als
  geändert und nie als aktuell gezählt.
- `phase`: siehe unten. Zusätzliche Felder (`latestState`, `latestId`, `latestSha`, `type`) sind willkommen.
- `fetchWarn` (optional): etwas, das nicht gelesen werden konnte, die Zeile aber nicht so falsch macht,
  dass es ein `fetchError` wäre, zum Beispiel die eigenen Domains bei Amplify (die gezeigte Adresse kann die
  Standardadresse sein). Die App zeigt es dezent an der Zeile.
- `triggeredSha` (optional, Hook): `lastSha` ist dann der Branch-Kopf, als der Hook feuerte, kein
  live gesehener Commit (der Host baut vielleicht einen anderen). Es zählt trotzdem die Commits seit dem
  Auslösen; die App muss es nicht live nennen. Die `phase` eines Hooks ist `queued` für `HOOK_QUEUED_SECS`
  (180) nach einem guten Auslösen, dann `ready`; seine `_status`-Zeile ist sofort `ready`, da
  `watch` durch Warten nichts mehr erfahren würde.

### Phase

`phase` ist eines von `queued`, `building`, `ready`, `failed`, `canceled`. Sie ist nur `null`, wenn es
gar keinen Deploy gibt oder die Plattform einen Zustand meldete, den der Provider nicht kennt. Jeder Provider
bildet seine eigenen Zustände ab. `CHANGED_RULE`, `watch` und `status` lesen nur `phase`; `lastState` bleibt
roh. Ein Deploy, der ersetzt wurde, bevor er live ging (Render `deactivated`), endet als `canceled`.

### bash 3.2

`deploys` läuft unter `/bin/bash` 3.2 von macOS. Dort ist `"${x:-{\}}"` der Text `{\}`, nicht `{}`:
eine leere Variable bricht dann `--argjson` und damit die ganze Liste. Setze den Standardwert in einer eigenen
Zeile und prüfe ihn (`[ -n "$x" ] || x='{}'`, dann `jq -e 'type == "object"'`).
`tests/providers/vercel.sh` schlägt fehl, wenn dieses Muster in `providers/` oder `lib/githost.sh` auftaucht.

## Überschreibungen

Für Tests und ungewöhnliche Aufbauten; im normalen Gebrauch ist keine nötig.

| Variable | Was |
|---|---|
| `DEPLOYS_VERCEL_TEAM` | Die Vercel-Team-ID, statt der gemerkten |
| `DEPLOYS_VERCEL_TIMEOUT` | Sekunden, die ein `vercel`-Aufruf dauern darf (60) |
| `DEPLOYS_VERCEL_ANY_SHA` | `1`: ein Produktions-`--sha`, von dem GitHub sagt, er liege nicht auf dem gemerkten Branch (ein Fork, ein anderer Branch), wird trotzdem deployt; ohne das abgelehnt (FEA-042) |
| `NETLIFY_API`, `CLOUDFLARE_API_BASE`, `DIGITALOCEAN_API` | Eine andere API-Adresse (Testserver) |
| `DEPLOYS_NETLIFY_POLLS` | Wie oft ein Netlify-Start nach seinem neuen Deploy sucht |
| `DEPLOYS_CLOUDFLARE_SELFTEST_TRIES` | Runden des Cloudflare-Selbsttests (je 5 s) |
| `DEPLOYS_CLOUDFLARE_TOGGLE` | Cloudflare: Push-Builds nur für einen Start einschalten |
| `DEPLOYS_CLOUDFLARE_SELFTEST_TTL` | Sekunden, die ein Cloudflare-Selbsttest für sein Projekt zählt (30 Tage) |
| `DEPLOYS_GITLAB_TIMEOUT` | Sekunden, die ein `glab api`-Aufruf dauern darf (60) |
| `DEPLOYS_GITLAB_CURL` | GitLab auch dann mit curl fragen, wenn `glab` da ist |
| `DEPLOYS_RENDER_NAME_TTL` | Sekunden, die Render Dienstnamen für Suchen behält (60; 0 = nie) |
| `DEPLOYS_NETLIFY_RULE_TTL` | Sekunden zwischen GitHub-Prüfungen einer unbestätigten Netlify-Regel (600) |
| `DEPLOYS_AMPLIFY_PARALLEL` | Amplify-Apps, die in einer Liste gleichzeitig gelesen werden (4) |
| `DEPLOYS_AMPLIFY_LOG_BYTES` | Bytes, die vom Ende jedes Amplify-Log-Schritts gelesen werden (262144) |
| `DEPLOYS_HOOK_STORE` | `keychain` oder `file`: wo Hook-URLs gehalten werden (file: Tests, Linux) |
| `FLY_API`, `RAILWAY_API`, `HEROKU_API`, `FIREBASE_API`, `GHPAGES_API`, `DENO_API`, `KOYEB_API` | Eine andere API-Adresse (Testserver) |
| `DENO_DEPLOY_ORG` | Die Deno-Deploy-Organisations-ID (oder `{"org":"<id>"}` in `deno.json` im Konfigurationsordner) |
| `FLY_ORG`, `FIREBASE_PROJECT` | Die Fly.io-Organisation (Standard `personal`) und das Firebase-Projekt, dessen Sites gelistet werden |
| `DEPLOYS_GHPAGES_SITES` | GitHub-Pages-Sites, `owner/repo[:workflow.yml[@branch]]`, durch Leerzeichen getrennt (oder `deploys ghpages add`) |
| `DEPLOYS_RAILWAY_POLLS`, `DEPLOYS_GHPAGES_POLLS` | Wie oft ein Railway-Redeploy oder ein GitHub-Workflow-Dispatch nach seinem neuen Deployment oder Lauf sucht (5, 6) |

## Hosts, deren API nicht bauen kann

Nicht jede Plattform lässt eine API einen Build aus einem Commit starten. Die Provider für solche Hosts sagen, was
„deploy“ bedeutet, in ihren `_meta`-Caps und auf ihrer Seite, und lehnen den Rest ab, bevor etwas gesendet wird
(`die "<label> cannot …"`, was `contract.sh` prüft):

| Provider | `deploy` ist | Abgelehnt |
|---|---|---|
| `fly` | ein Neustart der gestarteten Maschinen auf ihrem aktuellen Image | `--sha`, `--preview`, `--no-cache`, `off`, `cancel`, `rollback`, `logs` |
| `railway` | `serviceInstanceRedeploy` des neuesten Deployments | `--sha`, `--preview`, `--no-cache`, `off` |
| `heroku` | ein Neustart der Dynos (eine Deploy-ID ist eine Release-ID; `status` sieht auch auf die Dynos) | `--sha`, `--preview`, `--no-cache`, `off`, `cancel` |
| `firebase` | die neueste fertige Version freigeben, die neuer ist als die live | `--sha`, `--preview`, `--no-cache`, `off`, `cancel`, `logs` |
| `koyeb` | ein Redeploy des Dienstes mit seiner aktuellen Definition | `--sha`, `--preview`, `--no-cache`, `off`, `cancel`, `rollback`, `logs` |
| `deno` | ein Redeploy des neuesten Deployments als Produktion | `--sha`, `--preview`, `--no-cache`, `off`, `cancel`, `rollback`, `logs` |
| `ghpages` | ein `workflow_dispatch` des Workflows der Site auf ihrem Branch | `--sha`, `--preview`, `--no-cache`, `off`, `rollback`, `logs` |

Eine GraphQL-API (Railway) hat für jeden Aufruf eine URL, darum beantwortet `tests/fixtures/railway/POST_graphql_v2.json`
jede Abfrage mit allen Feldern auf einmal, und der Provider liest die, nach denen er gefragt hat.
Railway macht seine eigenen POSTs mit nur einem Versuch statt `http_call` (das nach einem 429 erneut fragt).

## Schlüssel

`key_of <p>` (in `deploys`) liefert den Schlüssel des Providers: die erste gesetzte Variable in `keyEnv`,
sonst den Schlüsselbund-Eintrag `deploy-center-<p>` (`security find-generic-password -a "$USER"
-s deploy-center-<p> -w`). Es gibt nichts aus und scheitert, wenn es keinen gibt. Schick den Schlüssel an curl auf
stdin (`-K -`), nie als Argument. Render liest auch seinen älteren Schlüsselbund-Namen `render-api-key`,
innerhalb von `render.sh`.

## Namen

`deploys logs web` findet den Provider über, der Reihe nach:

1. `p:name` ausgeschrieben (`render:web`);
2. `names.json` im Konfigurationsordner, `[{name, platform, id}]`, geschrieben bei jedem Lesen einer Liste. Ein
   Name, der bei zwei eingeschalteten Providern vorkommt, wird abgelehnt, mit dem `p:name`, das stattdessen zu nutzen ist;
3. `<p>_has <name>` bei jedem Provider, der an und bereit ist.

Die einfache Datei `names` (ein Name pro Zeile) bleibt für die Tab-Vervollständigung und `deploys ignore`.

## Funktionen unter xargs

`bash -c` unter `xargs -P` sieht nur exportierte Funktionen. Ein Provider, der parallel liest,
exportiert seinen Worker: `export -f render_last_of`.

## Tests

1. `tests/fixtures/<p>/` anlegen:
   - `HOST`: der Hostname der API, zum Beispiel `api.render.com`.
   - `env`: vor den Tests geladen. Sie enthält Stand-in-Schlüssel und `CONTRACT_ID`, `CONTRACT_NAME`
     und `CONTRACT_DEPLOY`, mit denen `_has`, `_status`, `_latest`, `_deploy_json` und `_url`
     aufgerufen werden.
   - `expect.json`: `{"<name>": "<phase>"}` für jedes Projekt in der Listen-Fixture.
   - `config/` (optional): Dateien, die zuerst in den Konfigurationsordner kopiert werden. Ein Provider, der standardmäßig aus ist,
     braucht dort `providers.json` (`{"enabled":["<p>","render","vercel"]}`).
   - `CONTRACT_DONE` (optional, in `env`): ein sed-Skript, das die Dateien von
     `CONTRACT_DEPLOY` in einen fertigen Deploy verwandelt, für die Prüfung von `deploys watch` (der Standard passt auf
     Render und Vercel).
   - `bin/` (optional): Stand-ins für die eigene CLI eines Providers, auf den PATH gelegt (Amplify: `aws`).
   - Eine Datei je API-Aufruf: `<METHOD>_<path>.json`, wobei `<path>` der URL-Pfad samt Query ist, mit
     jedem Zeichen außer Buchstaben, Ziffern, `.` und `-` als `_` (zum Beispiel
     `GET_v1_services_limit_100.json`). Die Datei enthält den Body, einen Zeilenumbruch und den HTTP-Status.
2. `tests/lib/fake-curl.sh` antwortet aus diesen Dateien und protokolliert `curl METHOD URL` in `$CALLS`.
   `CURLSTUB=401|503|down` simuliert Fehler. Ein Provider, der eine CLI nutzt (wie Vercel), bekommt ein
   Stand-in wie `tests/lib/fake-vercel.sh`. Die aws-CLI (Amplify) wird von
   `tests/lib/fake-aws.sh` aus Dateien `AWS_<service>_<command>[_<app id>[_<job id>]].json` beantwortet.
   Ein Provider ohne `env` fällt beim Vertrag durch; er wird nicht übersprungen.
3. `tests/providers/contract.sh` läuft für jede `providers/*.sh`. Es prüft die Funktionen, `_meta`,
   die Felder und die Phasen von `_json`, die TSV-Zeilen, dass eine fehlende Fähigkeit ohne Aufruf
   abgelehnt wird, und die An/Aus-Regeln. `tests/script-tests.sh` führt jede `tests/providers/*.sh` aus;
   ein Provider darf dort seine eigene Datei ergänzen.
4. `shellcheck --severity=warning providers/*.sh` muss sauber sein (CI führt es aus).

Die Fixtures sind öffentlich: nur Stand-in-Namen (`example`, `alpha`, `web`), nie ein echtes Projekt,
eine echte Team-ID, Domain oder ein echter Schlüssel.

## Checkliste für einen neuen Provider

- `providers/<p>.sh` mit jeder Funktion, `"defaultOn":false` in `_meta`.
- `tests/fixtures/<p>/`, und `bash tests/script-tests.sh` läuft durch.
- Eine Zeile in `CHANGELOG.md` unter Unreleased.
- Die App (A2) liest `deploys providers --json` und braucht für einen neuen Provider keine Änderung.
