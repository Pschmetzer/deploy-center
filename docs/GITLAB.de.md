# GitLab als Quelle

Die deutsche Fassung von [GITLAB.md](GITLAB.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Deploy Center zählt, was gemergt, aber nicht live ist: die Commits zwischen dem Live-Commit und dem
Branch, die Merge Requests darunter und die noch offenen Merge Requests. Bei einem Projekt, dessen
Repo auf GitLab liegt (gitlab.com oder dein eigenes GitLab), liest es dafür jetzt GitLab, genauso wie es
GitHub liest. Die App braucht keine Änderung: `vercel json`, `render json`, `changed --json` und
`details` liefern für beide dieselben Felder.

## Einrichten

Eines von beiden reicht. Sind beide da, wird glab benutzt.

**glab** (die GitLab-CLI):

```bash
brew install glab
```

```bash
glab auth login
```

Bei einem selbst betriebenen GitLab meldest du dich mit `glab auth login --hostname git.example.com` an.

**Ein Token**, ohne glab: ein Personal Access Token mit dem Scope `read_api`, abgelegt im
macOS-Schlüsselbund. Es wird zuerst an `GITLAB_HOST` ausprobiert und nur gespeichert, wenn GitLab es annimmt:

```bash
pbpaste | deploys gitlab set-token     # deploys gitlab forget-token entfernt es
```

`GITLAB_TOKEN` funktioniert weiterhin und hat Vorrang vor dem Schlüsselbund (für CI oder Linux), legt das Token aber
im Klartext in dein Shell-Profil.

Bei einem selbst betriebenen GitLab sagst du außerdem, wo es liegt:

```bash
export GITLAB_HOST=git.example.com
```

Das Token geht nur an `GITLAB_HOST` (gitlab.com, wenn nicht gesetzt), nie an einen anderen Host, den eine Repo-URL
nennt, und es geht über stdin an curl, sodass es nie in der Prozessliste auftaucht. Die App startet das
Skript selbst und übernimmt von deiner Login-Shell nur den `PATH`; `GITLAB_HOST` und `GITLAB_TOKEN` aus deinem Shell-Profil
kommen dort also nicht an: Nimm in der App glab, dessen Login glab selbst speichert. `deploys` im Terminal liest die
Variablen wie gewohnt aus deiner Shell.

Prüfe es:

```bash
deploys doctor
```

`gitlabCli` sagt, ob glab installiert ist, `gitlabLoggedIn`, ob glab bei
`GITLAB_HOST` angemeldet ist oder `GITLAB_TOKEN` dort akzeptiert wird. `deploys where` zeigt den GitLab-Benutzer.

## Welche Repos als GitLab gelten

Jede Plattform sagt, woraus ein Projekt deployt. Der Git-Link von Vercel hat einen Typ (`github`,
`gitlab`); Render liefert die Repo-URL. Im JSON ist `.repo`:

| Repo | `.repo` |
|---|---|
| GitHub | `owner/name`, wie bisher |
| gitlab.com | `gitlab.com/group/subgroup/name` |
| Selbst betriebenes GitLab | `git.example.com/group/name` |

Ein Host ist GitLab, wenn er `gitlab.com` ist, der Host in `GITLAB_HOST`, einer aus
`DEPLOYS_GITLAB_HOSTS` (mehrere Hosts, durch Leerzeichen getrennt) oder `gitlab` im Namen hat. Jeder andere
Host (Bitbucket, Gitea, ...) ist keins von beidem: Diese Projekte bleiben „branch head unknown“, wie bisher.

## Was gelesen wird

Alle Lesezugriffe gehen an `https://<host>/api/v4/projects/<group%2Fname>/`, über `glab api --hostname <host>`
oder curl.

| Was | GitLab-API | Entsprechung bei GitHub |
|---|---|---|
| Branch-Head | `repository/commits/<branch>` | `repos/…/commits/<branch>` |
| Wartende Commits | `repository/compare?from=<live>&to=<branch>` | `compare/<live>...<branch>` |
| Voraus, zurück, auseinandergelaufen | `repository/merge_base` von beiden; ist live kein Vorfahre, liefert der Vergleich in die andere Richtung `behindBy` | `status`, `behind_by` |
| Gemergte MRs in diesem Bereich | `See merge request group/name!12` oder `(!12)` in der Nachricht; für bis zu 10 Commits ohne so einen Hinweis `repository/commits/<sha>/merge_requests` (nur gemergte). Jeder MR wird einmal gezählt. | `(#12)`, `Merge pull request #12`, `commits/<sha>/pulls` |
| Offene MRs | `merge_requests?state=opened&per_page=100`; Entwürfe aus `draft`, Bots am Namen (Renovate, Dependabot, `project_…_bot`, `…-bot`) | `pulls?state=open` |
| Details: Commits und Autoren | der Vergleich: `author_name`, `committed_date`, `web_url` | `author.login`, `commit.committer.date` |
| Details: Dateien und Zeilen | die `diffs` des Vergleichs; `+`- und `-`-Zeilen werden gezählt | `files[].additions`, `deletions` |
| Details: CI des Branch-Heads | `repository/commits/<sha>/statuses`: einer pro Job; `failed`/`canceled` gilt als fehlgeschlagen, `running`/`pending`/`created` als laufend | Check Runs |

## Unterschiede zu GitHub

- **Kein Cache.** gh hält Vergleiche fünf Minuten im Cache; glab und die API-Aufrufe nicht. Ein Neuladen
  fragt GitLab erneut. GitLab begrenzt Anfragen pro Minute, nicht pro Stunde; ein Neuladen von ein paar Dutzend
  Projekten bleibt weit darunter.
- **Kein eigenes Budget.** GitLab hat kein Stundenbudget wie GitHub. Die einzige Prüfung, die es gibt,
  ist die von GitHub: Sind in der Stunde weniger als 300 GitHub-Anfragen übrig, liest ein Neuladen nur noch die
  Branch-Heads, auch für GitLab-Repos.
- **Nie eine Untergrenze.** GitHub listet höchstens 250 Commits eines Vergleichs; GitLab listet alle, sodass
  `pendingPartial` immer false ist.
- **Offene MRs in den Details haben keinen CI-Status** (`ci: "none"`): Die Merge-Request-Liste von GitLab
  enthält ihre Pipelines nicht, und für jeden einzelnen nachzufragen würde einen Aufruf pro MR kosten.
- **Bots** werden am Namen erkannt, da GitLab in diesen Antworten nur wenige Benutzer als Bots markiert.
- `.gitlab-ci.yml` zählt in den Details als riskante Datei, neben `.github/workflows/`.
- `deploys triggers` listet nur GitHub-Workflows; nach GitLab-Pipelines, die deployen, wird nicht gesucht.

## Vercel-Projekte auf GitLab

Wenn du Auto-Deploy ausschaltest (`deploys vercel autodeploy-off`), merkt sich das einen GitLab-Link als
`{"type":"gitlab","repo":"gitlab.com/group/name","projectId":…,"ref":…}`, und
`deploys vercel deploy` schickt Vercel dann eine GitLab-`gitSource` mit dieser Projekt-ID. Bei einem
Projekt, das früher getrennt wurde, sagst du, woraus es deployt:

```bash
deploys vercel map web gitlab.com/group/name main
```

Das schlägt die Projekt-ID auf GitLab nach, also muss glab oder `GITLAB_TOKEN` für diesen Host funktionieren.

## Ohne lib/githost.sh

Der GitLab-Code liegt in `lib/githost.sh`, neben `deploys` (und in der App unter
`Contents/Resources/lib/`). Eine ältere Kopie von `deploys` allein, ohne diesen Ordner, liest
GitHub weiterhin wie bisher; GitLab-Projekte bleiben dann „branch head unknown“.
