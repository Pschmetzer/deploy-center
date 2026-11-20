# Der Auto-Deploy-Wächter und Auto-Deploy für eine Weile erlauben

Die deutsche Fassung von [GUARD.md](GUARD.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Deploy Center schaltet Auto-Deploy aus, damit nichts ohne Klick baut. Es kann von selbst wiederkommen: jemand verbindet Git im Vercel-Dashboard neu, ein Render-Blueprint-Sync setzt `autoDeployTrigger` zurück, ein Teammitglied schaltet es um. Der Wächter bemerkt das und schaltet es wieder aus.

Willst du, dass Pushes bauen (ein hektischer Nachmittag, ein Vorfall), gib eine **Freigabe**: Auto-Deploy für 1 bis 168 Stunden an. Der Wächter lässt es an, bis die Freigabe endet, und schaltet es dann aus.

> Solange Auto-Deploy erlaubt ist, baut jeder Push und kostet Geld. Auch jeder gemergte Autofix-PR: Autofix deployt einen Fix nie selbst, aber bei eingeschaltetem Auto-Deploy tut es der Merge.

## Befehle

```bash
deploys vercel autodeploy-on my-project       # Git wieder verbinden aus dem gemerkten Repo (oder --all)
deploys render autodeploy-on my-service       # Auto-Deploy wieder „On Commit“ (oder --all)

deploys autodeploy allow vercel my-project 4  # 4 Stunden an, dann schaltet der Wächter es aus
deploys autodeploy allow render --all 1       # jeder Render-Dienst, 1 Stunde
deploys autodeploy allow all --all 24         # alles, 24 Stunden
deploys autodeploy allowed [--json]           # laufende Freigaben
deploys autodeploy revoke vercel my-project   # jetzt zurücknehmen (und ausschalten, was nichts anderes erlaubt)

deploys guard --dry-run                       # was er ausschalten würde; ändert nichts
deploys guard                                 # ein Lauf
deploys guard schedule on|off                 # alle 30 Minuten über launchd
deploys guard status [--json]                 # an/aus, letzter Lauf, was er tat, Freigaben
```

In der App hat **Einstellungen → Deploy → Auto-Deploy-Wächter** dasselbe: den Schalter, den letzten Lauf, laufende Freigaben mit Restzeit und **Jetzt zurücknehmen** sowie **Auto-Deploy erlauben …** für ein Projekt oder alle, für 1, 4 oder 24 Stunden.

## So funktioniert es

- `autodeploy-on`, Vercel: `POST /v9/projects/<p>/link` mit `{"type":"github","repo":"<org>/<repo>"}` aus `~/.config/deploys/vercel-repos.json`. Ein Projekt, dessen Repo dort nicht bekannt ist, bricht mit einem Fehler ab; setze es mit `deploys vercel map <p> <owner/repo> [branch]`. Prüfe nach dem Einschalten, dass **Settings → Git → Production Branch** zum `ref` in dieser Datei passt.
- `autodeploy-on`, Render: `PATCH /services/<id>` mit `{"autoDeployTrigger":"commit"}`.
- `autodeploy allow` schreibt zuerst die Freigabe und schaltet dann Auto-Deploy ein. Ein Lauf des Wächters dazwischen sieht sie schon. Schlägt das Einschalten für ein einzelnes Projekt fehl, wird die Freigabe wieder zurückgenommen. Mit `--all` bleiben Vercel-Projekte, deren Repo unbekannt ist, manuell (in der Ausgabe gezählt).
- Der Wächter liest jedes Vercel-Projekt und jeden Render-Dienst. Wo Auto-Deploy an ist und keine laufende Freigabe es deckt, schaltet er es aus: bei Vercel wird vorher das Repo gemerkt (wie bei `autodeploy-off`), bei Render geht der Trigger auf `off`. Dann sendet er eine Mitteilung (macOS; unter Linux `DEPLOYS_NOTIFY_CMD` setzen, siehe [CLI.md](CLI.md)).
- Vor jedem Umschalten nimmt der Wächter eine Sperre, die er mit `allow` und `revoke` teilt, und liest die Freigaben noch einmal. Eine Freigabe von eben gewinnt.
- Abgelaufene Freigaben werden zu Beginn jedes Laufs entfernt (nicht im Probelauf).
- Eine Plattform, die sich nicht lesen lässt, ist ein Fehler (Exit 1, Mitteilung), nie „nichts ist an“. Die andere Plattform wird trotzdem geprüft. Ein Projekt, das sich nicht umschalten lässt, stoppt den Rest nicht.
- Der erste Lauf nach `guard schedule on` ist ein Probelauf: eine Mitteilung sagt, was er ausschalten würde, ab dem nächsten Lauf tut er es. Der Job läuft alle 30 Minuten, solange dieser Mac wach ist; Log: `~/Library/Logs/DeployCenter-guard.log`.
- `revoke` ist nie ein Probelauf: Es entfernt die Freigabe und schaltet aus, was es allein angelassen hat. Wer `vercel my-project` zurücknimmt, während eine `all --all`-Freigabe läuft, lässt das Projekt an.

Plattformen, die der Wächter ansieht: Vercel, wenn die `vercel`-CLI da ist (oder Projekte gemerkt sind), Render, wenn ein Schlüssel gesetzt ist. Noch nicht Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean oder Coolify: Dort kann ein Teammitglied oder ein Dashboard-Klick automatische Builds wieder einschalten, ohne dass der Wächter es bemerkt. `deploys list --json` zeigt je Projekt das Feld `auto`; prüfe diese vorerst von Hand.

## Dateien

`~/.config/deploys/autodeploy-allow.json`: die Freigaben, Schlüssel → Ablauf (Unix-Sekunden).

```json
{ "vercel:my-project": 1794300000, "render:*": 1794290000, "*": 1794280000 }
```

`<platform>:<name>` ist ein Projekt (Render: der Dienstname, nicht die `srv-`-ID), `<platform>:*` jedes Projekt einer Plattform, `*` alles.

`~/.config/deploys/guard.json`: der letzte Lauf (`lastRun`, `lastDry`, `lastActions`) und `firstRunPending`.

## JSON für die App

`deploys autodeploy allowed --json` und `deploys guard status --json` haben die Form, die [GUARD.md](GUARD.md#json-for-the-app) zeigt. `action` ist `off` (ausgeschaltet), `wouldOff` (Probelauf), `failed` (ließ sich nicht umschalten; `error` sagt warum) oder `error` (die Plattform ließ sich nicht lesen; `project` ist null). `lastRun` ist vor dem ersten Lauf null.

## Exit-Codes

`guard`: 0 erledigt, 1 eine Plattform ließ sich nicht lesen oder ein Umschalten schlug fehl (der Rest ist erledigt).
`autodeploy allow`: 0 erledigt, 1 falsche Eingabe oder etwas ließ sich nicht einschalten.
`autodeploy revoke`: 0 erledigt, 1 etwas ließ sich nicht ausschalten.
