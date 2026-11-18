# Search and saved searches

The search field above the list filters projects as you type. It looks at names, repos, notes, branch and commit text. While you search, the field shows how many rows match ("3/41").

## Operators

Put operators next to ordinary words. Everything that is not an operator is searched as text.

| Operator | Shows |
| --- | --- |
| `is:failed` | projects whose last build failed |
| `is:waiting` | projects with commits waiting to go live |
| `host:render` (or `platform:render`) | only one host; the name is the CLI name of the platform, such as `vercel` or `render` |
| `repo:my-repo` | projects of one repo |

Examples (made-up names):

```text
is:failed host:render        failed Render services
is:waiting repo:my-shop      what waits in one repo
is:failed checkout           failed projects that mention "checkout"
```

An operator with an unknown host name is searched as plain text.

## Saved searches

The bookmark button next to the field keeps the current search, such as `is:failed host:render`. Click a saved search to run it again, or remove it. A saved search is only text on this Mac; running it never deploys anything.

## Repo groups

Projects that share a repo sit under one repo header. Click a header to fold it (the state is remembered). A header counts its failed projects and offers **Tick failed N** next to **Tick all** when only some failed. **More → Collapse all repo groups** and **Expand all repo groups** do all headers at once.

## In the command palette

The command palette has **Failed only (on/off)** and one line per saved search. A line fills the search box; nothing runs. Option-Command-F does the same as **Failed only**. Right-click a repo header for **Show only this repo**, which fills the search with `repo:name`.

## Merged fixes

When an [Autofix](AUTOFIX.md) pull request is merged, its row stands out until the fix is live. **More → Tick the N merged fixes** ticks all of them. It only ticks; deploying still needs your click.

## Copy the list

**More → Copy list of waiting projects** puts a Markdown list of what waits to go live on the clipboard. In demo mode the names are masked.
