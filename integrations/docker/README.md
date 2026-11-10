# Docker image

The image holds the `deploys` CLI and what it needs on Linux: bash, jq, curl, git, gh, `column`
and a pinned Vercel CLI.

```bash
docker build -f integrations/docker/Dockerfile -t deploys .          # from the repo root
docker run --rm -e VERCEL_TOKEN -e RENDER_API_KEY -e GH_TOKEN \
  -v "$PWD/deploys-config:/config" deploys changed --json
```

- Keys come from the environment. None are written into the image.
- `/config` is the config folder (`DEPLOYS_CONFIG`). Put your `vercel-repos.json` there, copied
  from `~/.config/deploys/`.
- The image runs as the unprivileged `node` user. Without arguments it runs `deploys doctor`.
- To use another Vercel CLI version: `--build-arg VERCEL_CLI_VERSION=…`.

Tested locally. The image builds, `doctor` runs, and the Vercel CLI reads `VERCEL_TOKEN`: a wrong
token gets a 403 from Vercel instead of "not logged in". The integration tests also pass inside
the image. Not tested: a run against real accounts.
