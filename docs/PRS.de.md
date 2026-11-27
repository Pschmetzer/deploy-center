# Pull Requests pflegen

Arbeiten viele Claude-Code-Sitzungen an denselben Repos, geraten ihre Pull Requests in Konflikt und bleiben liegen.
`deploys prs` sieht sich jeden offenen Pull Request an, den du geschrieben hast, in jedem Repo: Bei einem Konflikt
merged es die Basis in den Branch (mit Claude Code, wenn git es nicht allein schafft), lässt GitHub zurückliegende
Branches aktualisieren und merged die grünen. Beides ist aus, bis du es einschaltest.

```bash
deploys prs                          # deine offenen Pull Requests und was jeden aufhält
deploys prs set autoResolve on       # Konflikte lösen (Standard: aus)
deploys prs set autoMerge on         # grüne Pull Requests mergen (Standard: aus)
deploys prs schedule on              # alle 5 Minuten; der erste Durchlauf zeigt nur, was er täte
```

Immer: kein Rebase, kein Force-Push, nie `--admin`, nie mit roten Checks. Ein Versuch pro `repo#pr:headOid`. Branches,
auf denen eine laufende Claude-Code-Sitzung arbeitet, werden übersprungen, ebenso Durchläufe bei knappem RAM oder Swap.
Es wird nur gemergt, nichts deployt. Details: [PRS.md](PRS.md).
