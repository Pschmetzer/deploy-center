# Hosts and what they can do

What each host supports, from the `caps` each provider file reports (`deploys providers --json`).
Vercel and Render are on by default; the others are opt-in (`deploys providers enable <host>`).

| Host | Turn auto-deploy off | Deploy a given commit (`--sha`) | Cancel | Rollback | Build logs | Preview deploys |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| [Vercel](vercel.md) | yes | yes | yes | yes | yes | yes |
| [Render](render.md) | yes | yes | yes | yes | yes | no |
| [Netlify](netlify.md) | yes | no | yes | yes | no | no |
| [Cloudflare Pages](cloudflare.md) | yes | no | no | yes | yes | yes |
| [AWS Amplify](amplify.md) | yes | yes | yes | yes | yes | yes |
| [DigitalOcean App Platform](digitalocean.md) | yes | no | yes | yes | yes | no |
| [Coolify](coolify.md) | yes | yes | yes | yes | yes | no |
| [Deploy hook](hook.md) | no | no | no | no | no | no |

A "no" is what the host's API allows today or what Deploy Center has not checked against a live
account; the page of each host says which. A deploy hook only starts a build: a 2xx answer counts as ready.

Host pages follow roughly the same order: what it saves you, setup (with the token permissions it needs),
turning push-deploys off, deploying, other commands, undo (Amplify calls it Rollback, Coolify lists its commands in one section). To add a host, see [PROVIDERS.md](../PROVIDERS.md).

## Page template

Copy this outline for a new host page (the headings in this order, `deploys <host> …` commands in code):

```markdown
# <Host> in Deploy Center

One or two sentences: what it saves you, and what Deploy Center does not do for this host.

## What you need
The token or login, and the exact permissions or scopes it needs (say "read" and "write" separately).

## Turn it on
`deploys providers enable <host>`, then `pbpaste | deploys <host> set-key`.

## Turn push-deploys off
What `autodeploy-off` changes on the host, and what it leaves alone.

## Deploy by hand
`deploys <host> deploy <project>`; what `--sha`, `--preview`, cancel and rollback do here (or "not available" and why).

## Other commands
Logs, doctor, selftest, anything only this host has.

## Limits and rate limits
What the host's API allows today, and what was not checked against a live account.

## Undo
How to put the old setting back (the command if there is one, else the steps in the host's dashboard), and where Deploy Center keeps the old setting.
```
