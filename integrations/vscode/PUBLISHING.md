# Publishing the extension

Two registries: the **VS Code Marketplace** (VS Code) and **Open VSX** (Cursor, Windsurf,
VSCodium, Gitpod). Publish the same `.vsix` to both. Nothing here publishes by itself: there is
no workflow for it, and the steps below are done by hand by a maintainer.

## Before every release

1. Raise `version` in `package.json` and add a section to `CHANGELOG.md` (this folder).
2. Build and check:

   ```bash
   cd integrations/vscode
   npm ci
   npm test
   npm run package
   ```

   `npm run package` runs `vsce package`, which runs `vscode:prepublish` first (type check and a
   minified bundle). The result is `deploy-center-<version>.vsix`.
3. Look inside: `npx vsce ls` should list only `package.json`, `README.md`, `CHANGELOG.md`,
   `LICENSE`, `media/icon.png` and `dist/extension.js`.
4. Install the `.vsix` in VS Code and in Cursor (**Extensions: Install from VSIX…**) and check the
   status bar, the tree, a deploy (on a test project), a failed log and "Copy for AI".
5. Check the repo stays clean: `scripts/check-public.sh` (no real project names or IDs in the
   README or the screenshots).

## VS Code Marketplace

One-time setup:

1. Sign in at <https://marketplace.visualstudio.com/manage> with a Microsoft account and create
   the publisher **`deploycenter`** (the `publisher` field in `package.json`; change both if the
   ID is taken).
2. Create a Personal Access Token in Azure DevOps (<https://dev.azure.com>, User settings >
   Personal access tokens): organization **All accessible organizations**, scope
   **Marketplace > Manage**. Keep it in a password manager, never in the repo.

Each release:

```bash
npx vsce login deploycenter        # asks for the token once
npx vsce publish --packagePath deploy-center-<version>.vsix
```

Or upload the `.vsix` by hand on the publisher page (**New extension > Visual Studio Code**).
The listing goes live after an automatic scan, usually within minutes.

## Open VSX (Cursor, Windsurf)

One-time setup:

1. Sign in at <https://open-vsx.org> with GitHub, and link an Eclipse account (Settings >
   Profile). Sign the Eclipse Publisher Agreement when asked.
2. Create an access token (Settings > Access Tokens).
3. Create the namespace once, matching `publisher`:

   ```bash
   npx ovsx create-namespace deploycenter -p <token>
   ```

   To get the verified badge, claim the namespace:
   <https://github.com/EclipseFdn/open-vsx.org/issues/new/choose> ("Claim namespace ownership").

Each release:

```bash
npx ovsx publish deploy-center-<version>.vsix -p <token>
```

Cursor and Windsurf read Open VSX; a new version shows up there within a day.

## Tokens in CI (later, optional)

If publishing is ever automated, store the tokens as repository secrets (`VSCE_PAT`,
`OVSX_PAT`), run it only on a tag push, and pass them as environment variables
(`vsce publish -p "$VSCE_PAT"`, `ovsx publish -p "$OVSX_PAT"`), never in the workflow text.
