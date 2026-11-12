---
description: Roll one project's production back to the deploy before, after asking the user to confirm.
argument-hint: <project>
disable-model-invocation: true
allowed-tools: Bash(deploys history *) Bash(deploys status *)
---

Roll **$ARGUMENTS** back to the deploy that was live before the current one, but only after the user
confirms. A rollback changes a live site at once.

If a project was given, check it first: it must be one project name, a single word of letters, digits and
`. _ : -` only (no spaces, no `;`, `&`, `|`, `$`, quotes or slashes). If it is anything else, say
"That is not one project name." and stop. Never put it into a command otherwise. If no project was
given, ask which one and stop.

1. Run `deploys history $ARGUMENTS 5` and show the last deploys: which one is live now, and which
   one production would go back to.
2. Ask: "Roll back $ARGUMENTS to the deploy before? Production changes now. (yes/no)".
   **Stop and wait for the answer.** Running this command is not the confirmation. Only a clear yes
   in the user's next message is.
3. On yes, roll back exactly this one project:
   - Vercel: `deploys vercel rollback $ARGUMENTS`
   - Render: `deploys render rollback $ARGUMENTS`
   Claude Code asks for permission for this command; that is on purpose.
4. Report the result in one line, then `deploys status --json` for its state.

On anything but a clear yes, change nothing. Never roll back other projects, never deploy, and never
turn auto-deploy back on.
