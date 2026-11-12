# Netlify

Netlify is off by default. Turn it on with:

```bash
deploys providers enable netlify
```

## Why it is worth it

Since September 2025 Netlify bills in credits, and every production deploy costs 15 of them.
When every push to the production branch builds, a busy day can cost more than a whole
month of deploying once a day by hand.

## How it works

Netlify has no API switch for "do not build on push" that still lets you deploy.
`build_settings.stop_builds` ("Stop builds" in the UI) also blocks builds from the API and from
build hooks, so Deploy Center does not use it.

What it does instead:

1. **A build hook.** `autodeploy-off` creates a build hook named `deploy-center` on the site,
   or reuses one that already exists. Its URL is kept in `~/.config/deploys/netlify-hooks.json`
   (mode 0600). Anyone who has that URL can start a build, so it is never printed. If that file
   is ever unreadable it is kept as `netlify-hooks.json.bak` and started again. When the site's
   production branch changes, the next `autodeploy-off` moves the hook to it (same URL); until
   then the site is not deployable.
2. **An ignore rule in your repo.** Before every build Netlify runs the `ignore` command and
   skips the build when the command exits 0. Netlify sets `INCOMING_HOOK_TITLE` only for builds a
   build hook started
   ([docs](https://docs.netlify.com/configure-builds/environment-variables/#build-hook-metadata)),
   so this rule skips everything else:

   ```toml
   [build]
     ignore = "[ -z \"$INCOMING_HOOK_TITLE\" ]"
   ```

3. **Deploying** posts to the hook. Deploy Center then reads the site's deploy list until a
   deploy shows up that was not there before the call. That deploy is the one it follows.

## Setup

1. Create a personal access token at app.netlify.com > User settings > Applications >
   Personal access tokens. Then store it. It is checked against Netlify before it is saved:

   ```bash
   pbpaste | deploys netlify set-key
   ```

   You can also set `NETLIFY_AUTH_TOKEN` in the environment instead, for CI or a server. The
   environment wins over the keychain (service `deploy-center-netlify`).

2. Turn auto-deploy off for a site. This creates the hook and prints the netlify.toml step:

   ```bash
   deploys netlify autodeploy-off <site>
   ```

3. Add the `ignore` line to `netlify.toml` and merge it to the production branch. If the site
   has a base directory, the file goes there. If the file already has a `[build]` section, add
   only the `ignore` line to it.

4. Run `autodeploy-off` again. It reads the file through `gh` and, once it finds the rule, marks
   the site as deployable. Until then `deploys netlify deploy <site>` refuses: without the rule,
   every push would still build.

   If your repo is not on GitHub, or `gh` cannot read it, check the file yourself and record
   it by hand:

   ```bash
   deploys netlify autodeploy-off <site> --rule-added
   ```

Deploy Center also looks again on its own: `deploys netlify list` re-checks every site that
has a hook but no confirmed rule, unless `DEPLOYS_NO_GITHUB` is set.

## What you can and cannot do

| | |
|---|---|
| Deploy | yes, always the newest commit of the production branch |
| Deploy a given commit (`--sha`) | no: a build hook cannot choose a commit |
| Preview deploys from here | no |
| Cancel a deploy | yes |
| Roll back | yes: restores the ready production deploy before the live one. A restore does not build, so it costs no build credits. |
| Build log | no: Netlify's REST API does not give it. `deploys logs` shows the state, the error message and a link to the log in the dashboard. |

Builds that the rule skipped show up at Netlify as canceled ("no content change"). Deploy
Center leaves them out when it shows the last deploy.

## Trade-offs

- **Deploy previews and branch deploys stop too.** A pull request build has no
  `INCOMING_HOOK_TITLE` either. That is usually what saves the most credits. If you want previews
  but no production builds on push, use this rule instead. Previews keep costing credits.

  ```toml
  [build]
    ignore = "[ \"$CONTEXT\" = production ] && [ -z \"$INCOMING_HOOK_TITLE\" ]"
  ```

  Deploy Center accepts any `ignore` line that checks `INCOMING_HOOK_TITLE`.
- **The rule replaces Netlify's default ignore.** Normally Netlify skips a build when nothing
  changed in the base directory. A deploy from here always builds.
- **Other build hooks still build.** A CMS or a scheduled hook sets `INCOMING_HOOK_TITLE` too.
  That is on purpose: those builds were started deliberately.
- **Each skipped build still starts**: Netlify clones the repo and runs the ignore command.
  It ends before the build and publishes nothing, so it is not a production deploy. Check
  your usage page once to confirm how your plan counts it.

## Undo

1. Remove the `ignore` line from `netlify.toml`, or change it back to your earlier one, and
   merge. From then on every push builds again.
2. Optionally delete the `deploy-center` build hook in Site configuration > Build & deploy >
   Build hooks, and remove the site from `~/.config/deploys/netlify-hooks.json`.
3. To remove the token: `security delete-generic-password -s deploy-center-netlify`.
4. `deploys providers disable netlify` hides Netlify again.
