---
description: Deploy one project to production after asking the user to confirm.
argument-hint: <project>
disable-model-invocation: true
allowed-tools: Bash(deploys changed *) Bash(deploys notes *)
---

Deploy the project **$ARGUMENTS** to production, but only after the user confirms.

If no project was given, run `deploys changed --json`, list what is waiting, and ask which one. Stop.

1. Run `deploys changed --json` and find the entry named `$ARGUMENTS` (or `platform:name`). If it is
   not in the list, look at the exit code and stderr first: exit 1 means some projects could not be
   read, and stderr names them. If `$ARGUMENTS` is one of those, say its state is unknown (and why)
   and stop; do not call it live. Only when the command exited 0 (or stderr does not name it) say it
   is already live (or unknown) and stop.
2. Show what would go live: platform, the number of commits, the newest commit message. For more
   detail, `deploys notes $ARGUMENTS` gives the commits as release notes.
3. Ask: "Deploy $ARGUMENTS to production now? (yes/no)". **Stop and wait for the answer.** Running
   this command is not the confirmation. Only a clear yes in the user's next message is.
4. On yes, deploy exactly this one project, on whichever platform it is (Vercel, Render, Netlify,
   Cloudflare, Amplify, DigitalOcean, Coolify, a deploy hook):
   `deploys deploy $ARGUMENTS --wait`
   (`deploys deploy <platform>:<name> --wait` when the name is on two platforms). It checks the
   deploy window and approvals. If it refuses (window closed, approval missing), report that and
   stop: never add `--force`.
5. Report the result in one line. If the build failed, offer `/deploy-center:deploys-fix $ARGUMENTS`.

On anything but a clear yes, deploy nothing. Never use `deploy-changed`, never deploy other
projects, never use `--force`, never roll back, and never turn auto-deploy back on.
