# Hosts and what they can do

What each host supports, from the `caps` each provider file reports (`deploys providers --json`).
Vercel and Render are on by default; the others are opt-in (`deploys providers enable <host>`).

| Host | Turn auto-deploy off | Deploy a given commit (`--sha`) | Cancel | Rollback | Build logs | Preview deploys |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Vercel | yes | yes | yes | yes | yes | yes |
| Render | yes | yes | yes | yes | yes | no |
| [Netlify](netlify.md) | yes | no | yes | yes | no | no |
| [Cloudflare Pages](cloudflare.md) | yes | no | no | yes | yes | yes |
| [AWS Amplify](amplify.md) | yes | yes | yes | yes | yes | yes |
| [DigitalOcean App Platform](digitalocean.md) | yes | no | yes | yes | yes | no |
| [Coolify](coolify.md) | yes | yes | yes | yes | yes | no |
| [Deploy hook](hook.md) | no | no | no | no | no | no |

A "no" is what the host's API allows today or what Deploy Center has not checked against a live
account; the page of each host says which. A deploy hook only starts a build: a 2xx answer counts as ready.

Every host page follows the same order: what it saves you, setup (with the token permissions it needs),
turning push-deploys off, deploying, other commands, undo. To add a host, see [PROVIDERS.md](../PROVIDERS.md).
