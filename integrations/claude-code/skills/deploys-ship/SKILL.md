---
description: Deploy one project to production after asking the user to confirm.
argument-hint: <project>
disable-model-invocation: true
allowed-tools: Bash(deploys changed *) Bash(deploys notes *)
---

Deploy the project **$ARGUMENTS** to production, but only after the user confirms.

If a project was given, check it first: it must be one project name, a single word of letters, digits and
`. _ : -` only (no spaces, no `;`, `&`, `|`, `$`, quotes or slashes). If it is anything else, say
"That is not one project name." and stop. Never put it into a command otherwise.

If no project was given, run `deploys changed --json`, list what is waiting, and ask which one. Stop.

1. Run `deploys changed --json` and find the entry named `$ARGUMENTS`. If it is not in the list,
   say it is already live (or unknown) and stop.
2. Show what would go live: platform, the number of commits, the newest commit message. For more
   detail, `deploys notes $ARGUMENTS` gives the commits as release notes.
3. Ask: "Deploy $ARGUMENTS to production now? (yes/no)". **Stop and wait for the answer.** Running
   this command is not the confirmation. Only a clear yes in the user's next message is.
4. On yes, deploy exactly this one project:
   - Vercel: `deploys vercel deploy $ARGUMENTS --wait`
   - Render: `deploys render deploy $ARGUMENTS`, then `deploys watch $ARGUMENTS`
5. Report the result in one line. If the build failed, offer `/deploy-center:deploys-fix $ARGUMENTS`.

On anything but a clear yes, deploy nothing. Never use `deploy-changed`, never deploy other
projects, never roll back, and never turn auto-deploy back on.
