# Sicher ausprobieren

Die deutsche Fassung von [SAFE-START.md](SAFE-START.md). Verlinkte Seiten ohne eigene deutsche Fassung sind englisch.

Drei Schritte: erst nur ansehen, dann ein Projekt ändern, dann alle. Jeder Schritt lässt sich zurücknehmen ([AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy)).

## 1. Nur ansehen

Die App zu öffnen ändert nichts bei Vercel, Render oder GitHub. Sie liest deine Projekte und zeigt, welche noch bei jedem Push deployen. Nichts ändert sich, bis du **Auto-Deploy ausschalten** oder **Deploy** drückst und bestätigst.

Dasselbe im Terminal. Jeder Befehl hier liest nur:

```bash
deploys doctor            # was ist verbunden
deploys vercel list       # AUTO (owner/repo) oder manual, je Projekt
deploys render list       # Auto-Deploy-Einstellung je Service
deploys changed           # was auf GitHub gemergt und nicht live ist
deploys triggers          # Builds der letzten 24 h, die niemand von hier gestartet hat, Workflows, die deployen
deploys deploy-changed    # ohne --yes: zeigt nur, was es deployen würde
```

Am wichtigsten ist `deploys triggers`. Ein GitHub-Workflow oder ein Deploy-Hook, der von allein deployt, baut weiter, auch wenn Auto-Deploy aus ist.

## 2. Ein Projekt

Nimm ein Projekt, das ein paar Minuten ausfallen darf.

**Vercel**

```bash
deploys vercel autodeploy-off mein-projekt       # entfernt die Git-Verbindung, merkt sich das Repo
deploys vercel deploy mein-projekt --preview     # erst eine Vorschau, nicht Production
deploys vercel deploy mein-projekt               # dann Production
deploys watch mein-projekt                       # bis es live oder fehlgeschlagen ist
```

**Render**

```bash
deploys render autodeploy-off mein-service       # stellt Auto-Deploy auf Off
deploys render deploy mein-service
deploys watch mein-service
```

In der App: Rechtsklick auf die Zeile für **Vorschau** und **Zurückrollen**. Stimmt etwas nicht, stellt `deploys vercel rollback mein-projekt` oder `deploys render rollback mein-service` das Deploy wieder her, das vorher live war.

Schick einen Commit ins Repo des Projekts und prüfe, dass kein Build startet. Mit angemeldeter GitHub-CLI führt `deploys changed` das Projekt dann als wartend auf.

## 3. Alle Projekte

```bash
deploys vercel autodeploy-off --all
deploys render autodeploy-off --all
```

Oder drück in der App **Auto-Deploy ausschalten**. Sie listet vor der Bestätigung jedes betroffene Projekt auf.

Ab dann reicht ein Deploy am Tag. In der App: **Alle mit Änderungen anhaken**, dann **Deploy**. Im Terminal: `deploys deploy-changed --yes`.

## Ohne die App (nur CLI)

Dieselbe Reihenfolge geht im Terminal, und nichts ändert sich, bis du es sagst:

```bash
deploys status                          # was ist verbunden, was wartet; ändert nichts
deploys list                            # deine Projekte und ob Auto-Deploy an ist; ändert nichts
deploys deploy-changed                  # eine Liste dessen, was deployt würde; deployt nur mit --yes
```

Schalte dann ein Projekt ab (`deploys vercel autodeploy-off mein-projekt`), schick einen Commit und prüfe, dass kein Build startet, und nimm erst dann `--all`. Zurück geht es mit `deploys vercel autodeploy-on mein-projekt`.
