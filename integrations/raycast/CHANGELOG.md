# Deploy Center Changelog

## [Initial Version] - {PR_MERGE_DATE}

- **Waiting Deploys**: projects with commits or pull requests that are not live, with the age of the oldest. Deploy (after a confirmation), open the site or dashboard, copy release notes, or show the project in Deploy Center.
- **Deploy Status**: projects that are building, and projects whose newest deploy failed. For a failed one: Show Log (the newest build log, secrets masked) and Copy Build Error (the first error block with a short prompt).
- **Deploy All Changed**: shows every project with waiting commits, and deploys exactly those after a confirmation, in one `deploys deploy-changed` run. If the CLI would start a different set by then, nothing starts. After a run the list is read again and "Deploy All" stays off.
- Every platform `deploys` knows, not only Vercel and Render; a name on two platforms is passed as `platform:name` to notes and open.
- A timeout ends the CLI and everything it started. "Not logged in" only from the CLI's errors (an HTTP 401/403), never from a commit text.
- Waiting Deploys and Deploy Status show the last list at once and read it again in the background.
