# Publishing to the Raycast Store

This folder is not on the Store yet. Raycast extensions are published as a pull request to
[raycast/extensions](https://github.com/raycast/extensions). The steps (see
[Publish an Extension](https://developers.raycast.com/basics/publish-an-extension)):

1. **Author.** `author` in `package.json` must be the Raycast account name of whoever publishes
   (raycast.com/<name>). It is set to `pschmetzer`; change it if the account name differs.
2. **Screenshots.** Take 2000×1250 PNGs with Raycast's window capture (Window Capture in the
   Raycast settings, "Save to Metadata"). They go into `metadata/` as `deploy-center-1.png`, … Then
   uncomment the image lines in `README.md`. Do not show real project names you would rather keep private.
3. **Check.** From this folder:

   ```bash
   npm ci
   npm run lint
   npm run build
   ```

   `npm run lint` checks the author and the manifest against raycast.com, so it needs network access.
4. **Try it.** `npm run dev` loads it into Raycast. Run each command once with Deploy Center
   installed, once with the app missing (error view), and once with nothing waiting (empty state).
5. **Submit.** `npm run publish`. It forks raycast/extensions, copies this folder to
   `extensions/deploy-center`, and opens the pull request. Fill in the PR template there.
   Raycast's reviewers may ask for changes; answer them in that PR.
6. **Updates.** Later changes: add a line on top of
   `CHANGELOG.md` under `## [Change] - {PR_MERGE_DATE}`, and run `npm run publish` again. If
   someone else changed the Store copy, `npx ray pull-contributions` (the `ray` from package-lock.json, not `@latest`) first.

Keep the two copies in step: changes are made here first, then published.
