# pre-push hook

Before a push, the hook says how many builds the push would start on projects that still deploy
on push:

```
deploys: this push starts 2 build(s), auto-deploy is still on for:
  vercel  site  (production, branch main)
  render  api  (production, branch main)
```

The hook knows how each platform reacts to a push. Vercel, with Git connected, builds every
branch you push: the production branch as production, any other branch as a preview. Render
builds only the branch it is set to. A project counts when its repo is the remote you push to.

```bash
cp integrations/hooks/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
```

| Setting | |
|---|---|
| (none) | Warn, then push. |
| `git config deploys.prepush.block true` | Stop the push when it would start builds. `git push --no-verify` goes anyway. |
| `git config deploys.prepush.skip true` or `DEPLOYS_PREPUSH=off` | Do not check. |

If `deploys` or `jq` is missing, the remote is not on GitHub, or something fails, the push goes
ahead without a word. The check reads both platforms (no GitHub calls), so expect a few
seconds. After `DEPLOYS_PREPUSH_TIMEOUT` seconds (default 20) it gives up and lets the push go.
