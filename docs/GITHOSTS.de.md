# Einen Git-Host hinzufügen

Die deutsche Fassung von [GITHOSTS.md](GITHOSTS.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

[PROVIDERS.md](PROVIDERS.md) handelt davon, wo ein Projekt *deployt* wird (Vercel, Render, …). Diese Seite handelt davon, wo sein *Code liegt*: der Git-Host, den `deploys` fragt „Was wartet?“. GitHub und GitLab sind eingebaut. Bitbucket und Gitea sind die meistgewünschten nächsten. Ein Repo auf einem Host, den `deploys` nicht fragen kann, wird als `unknown` aufgeführt und nie als wartend gezählt.

Der Code ist `lib/githost.sh` (GitLab und die Dispatcher) und, für GitHub, die Funktionen `head_of`, `pending_of` und `open_prs_of` in `deploys`. Lies zuerst [GITLAB.md](GITLAB.md), was ein Benutzer sieht.

## Wie ein Repo geschrieben wird

Jedes Plattform-JSON hat ein Feld `repo`, den Slug des Repos:

| Slug | Host |
| --- | --- |
| `owner/name` | GitHub (der Standard, so belassen wie immer) |
| `gitlab.com/group/sub/name` | GitLab: erst der Host, dann der volle Projektpfad |
| `git.example.com/group/name` | ein selbst betriebenes GitLab, siehe `githost_of` |

`githost_split` macht aus einer URL oder einem Slug (`https://`, `ssh://`, `git@host:path`, `.git` entfernt) `host path`. `githost_of <slug>` antwortet `github`, `gitlab` oder `unknown`. Ein neuer Host beginnt hier: Bring `githost_of` bei, welche Hosts deine sind (GitLab akzeptiert außerdem `GITLAB_HOST`, `DEPLOYS_GITLAB_HOSTS` und jeden Host mit `gitlab` im Namen), und bring `GITHOST_SLUG_JQ` und `GITHOST_VERCEL_LINK_JQ` bei, wie aus der Repo-URL einer Plattform dein Slug wird.

## Die Funktionen, die ein Host bereitstellt

Die drei Dispatcher (`githost_head_of`, `githost_pending_of`, `githost_open_prs_of`) rufen die eigenen Funktionen eines Hosts mit denselben Argumenten und denselben **Ausgabedateien** auf wie die GitHub-Funktionen. Jede Funktion schreibt eine JSON-Zeile in eine Datei in `$out`, benannt mit `githost_cache_name`, und schreibt nichts, wenn sie nicht antworten kann (sie lässt den Lauf nie scheitern: `deploys` zeigt dann „branch head unknown“, statt zu raten).

| Funktion | Schreibt | Eintrag (`key`, `value`) |
| --- | --- | --- |
| `<host>_head_of <repo> <ref> <out>` | den neuesten Commit eines Branches | `key` `repo@ref`; `value` `{at, msg, sha}`, oder `{error}`, wenn das Fragen fehlschlug (nimm `head_why` für den Text) |
| `<host>_pending_of <repo> <base> <ref> <out>` | die Commits vom Live-Commit (`base`) bis zum Branch (`ref`) | derselbe Eintrag, den `pending_of` schreibt: die Commits, die Merge Requests darunter und wie der Branch zu dem steht, was live ist (voraus, hinterher, auseinandergelaufen oder „rewritten“, wenn `base` weg ist) |
| `<host>_open_prs_of <repo> <out>` | offene Pull oder Merge Requests | `{all, partial, drafts, bots}` |

Außerdem nötig, damit der Rest der CLI für ein Repo auf deinem Host funktioniert:

- `<host>_details <repo> <base> <ref>`: das JSON von `deploys details` (Commits, Dateien, Checks).
- `<host>_ci_of <slug> <sha or branch>`: das CI-Urteil `{state, reason, checks, failed, running}`, `state` eines von `green`, `red`, `pending`, `none`, `unknown`. Eine Pipeline, die auf einen Menschen wartet, ist nicht `pending`.
- `<host>_risk_of <slug> <base> <ref>`: das Risiko dessen, was wartet (`deploys risk`).
- `<host>_default_branch <slug>` und, falls eine Plattform es braucht, eine Projekt-ID.
- `<host>_logged_in` und `<host>_user`, für `deploys doctor` und `deploys where`.

Dispatch-Zeilen, die du ergänzen musst: die drei `githost_*`-Funktionen in `lib/githost.sh` und die Stellen in `deploys`, die `githost_of` prüfen (Details, CI, Standard-Branch).

## Regeln, die es sicher halten

- **Nur lesen.** Jeder Aufruf ist ein GET. Ein Rate-Limit (429), ein Serverfehler (5xx), keine Antwort oder ein hängender Aufruf wird dreimal erneut gefragt, im Abstand von 2 s und dann 4 s; ein Schreibzugriff wird nie wiederholt.
- **Das Token geht nur an einen Host.** Das `GITLAB_TOKEN` von GitLab geht über stdin an curl (nie in argv) und nur an den Host, den `GITLAB_HOST` nennt: Eine Repo-URL, die von einer Plattform kommt, darf kein Token woandershin schicken können. Ein neuer Host braucht dasselbe: eine eigene Token-Variable und eine Host-Prüfung.
- **Kein privates Projekt wird zu „rewritten“.** Ein 404 kann „privat“ heißen. Nenne die Historie nur dann umgeschrieben, wenn der Branch selbst noch lesbar ist.
- **Die Seitenzahl ist begrenzt.** GitLab liest bis zu fünf Seiten mit je 100 offenen Requests; mehr wird als `partial` gemeldet.
- **Ohne irgendeinen Git-Host** (`githost_available` falsch) fügt `with_heads` keine Heads hinzu und die App zeigt keine Zähler; das Deployen funktioniert weiter.

## Tests

`tests/providers/gitlab.sh` ist das Vorbild. Es braucht kein Netzwerk: Es legt Attrappen für `glab` und `curl` in ein temporäres `bin/` und antwortet nach Anfragepfad (`projects/me%2Fapp/repository/commits/main`, `…/compare?from=…&to=…`, `…/merge_requests?state=opened&per_page=100&page=1`). Es prüft:

- ein Fehler wird erneut gefragt, und ein hängender Aufruf endet;
- das 404 eines privaten Projekts ist nicht „history rewritten“;
- die Merge Requests, aus denen ein Commit kam, werden einmal gefragt und zwischengespeichert;
- offene Requests jenseits einer Seite werden gezählt.

`tests/script-tests.sh` deckt den Dispatch ab (`githost_of` für jede Schreibweise eines Repos). Ergänze dieselben Fälle für deinen Host und führe `bash tests/all.sh --quick` aus.

## Einen Pull Request öffnen

Halte ihn klein: ein Host, die Funktionen oben, die Tests und eine Doku-Seite wie [GITLAB.md](GITLAB.md). Nimm ausgedachte Projektnamen. Siehe [CONTRIBUTING.md](../CONTRIBUTING.md).
