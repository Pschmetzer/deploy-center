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
  A folder mounted on `/config` keeps its owner from the host, so `node` may not write to it
  (`deploys ignore`, a remembered team). Run as your own user then:
  `docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/deploys-config:/config" …`.
- Only `deploys`, `providers/`, `lib/` and the healthcheck script are sent to the build (`Dockerfile.dockerignore`), not
  the whole repository.
- To use another Vercel CLI version: `--build-arg VERCEL_CLI_VERSION=…`.
- **A smaller image** when you do not use Vercel: `--build-arg WITH_VERCEL=0` leaves the Vercel CLI
  out. Measured here: 567 MB instead of 1.09 GB. Render, Netlify and the other hosts need only
  curl; a Vercel command then says that `vercel` is missing.

## Healthcheck

The image has a `HEALTHCHECK` (every 60 s). [`healthcheck.sh`](healthcheck.sh) checks that `deploys --version` answers, that
`jq` and `curl` are there and that the providers folder holds the hosts. It never asks the network: a host that is down must
not get the container restarted in a loop. `docker inspect --format '{{json .State.Health}}' <container>` shows the last
answer, for example `unhealthy: the scheduler's last heartbeat is 600 s old (more than 300)`. A one-off `docker run` is gone
before it matters; the check is for a container that stays up.

## Cron variant

[`Dockerfile.cron`](Dockerfile.cron) is the CLI image plus a small scheduler ([`scheduler.sh`](scheduler.sh)) and the status
page, badge and report scripts. It runs read-only jobs from `/config/jobs.conf` and **cannot deploy**: a job is one of
`deploys <changed|status|plan|list|digest|notes|history|risk|doctor|explain|ledger|simulate|metrics|costs|window|freeze>`,
`statuspage`, `badges`, `badge-stats` or `report`. A line with `--yes`, or `deploys deploy`, `rollback` or anything else, is
refused when the file is read, before any job runs.

```bash
docker build -f integrations/docker/Dockerfile -t deploys .            # from the repo root
docker build -f integrations/docker/Dockerfile.cron -t deploys-cron .
cp integrations/docker/jobs.example.conf deploys-config/jobs.conf     # then edit it
docker run -d --name deploys-cron -e VERCEL_TOKEN -e RENDER_API_KEY -e GH_TOKEN \
  -v "$PWD/deploys-config:/config" -v "$PWD/deploys-data:/data" deploys-cron
```

```text
every 30m out=/data/changed.json deploys changed --json
every 6h  statuspage --config /config/statuspage.json --out /data/status
daily 06:10 badge-stats /data/badges --days 30
weekly mon 07:30 report --out /data/reports --period week
```

A job starts with `every 30m|6h|1d`, `daily HH:MM` or `weekly mon HH:MM` (UTC), then an optional `out=FILE` (the output is
written there, atomically), then the job. Words are split at spaces: no quotes, pipes or redirects. `every` jobs run at start
and then after that long; `daily` and `weekly` jobs run once from their minute on. A failed job is logged and tried again at
its next time; a job that runs longer than `DEPLOYS_JOB_TIMEOUT` seconds (600) is stopped. The log goes to
`docker logs`, with no key in it. `docker run … deploys-cron --check` reads the file and prints the plan; `--once` runs every
job now and exits.

Jobs only read: each runs with `DEPLOYS_READONLY=1`, and a flag or sub-command that changes something is refused when the file
is read (`freeze clear`, `doctor --fix`, `digest --post`). `docker stop` ends the scheduler at once (exit 143) and takes the
running job and its half-written output with it. The heartbeat comes from a ticker of its own, so a job that runs for
minutes does not make the container "unhealthy".

| Variable | Meaning |
| --- | --- |
| `DEPLOYS_JOBS` | the schedule file (default `/config/jobs.conf`) |
| `DEPLOYS_JOB_TIMEOUT` | seconds a job may run (default 600) |
| `DEPLOYS_INTEGRATIONS` | where the integrations are (default `/opt/deploy-center/integrations`) |
| `DEPLOYS_DIR` | the folder with `providers/` (set by the image) |
| `DEPLOYS_HEARTBEAT_FILE` | the heartbeat file (default `/tmp/scheduler.heartbeat`) |
| `DEPLOYS_HEARTBEAT_MAX` | how old the heartbeat may be for the healthcheck, in seconds (default 300) |
| `DEPLOYS_PING_URL` | an `https://` URL asked after every job that worked (healthchecks.io, Uptime Kuma push): a dead man's switch |

The scheduler writes a heartbeat (`/tmp/scheduler.heartbeat`) at every look, and the healthcheck says "unhealthy" when it is more
than 5 minutes old. [`compose.example.yml`](compose.example.yml) runs it as a service with a read-only root file system, no
capabilities, keys passed by name from your shell and the same healthcheck; its `once` service (`docker compose run --rm once`)
runs every job once.

Tested here without Docker: the scheduler (clock, due times, refused jobs), the healthcheck and the compose file are run by
`integrations/tests/ops.sh` against stand-ins. Not tested here: building the two images (CI builds only `Dockerfile`; there is
no step for `Dockerfile.cron` yet), and a run against real accounts.

Tested locally. The image builds, `doctor` runs, and the Vercel CLI reads `VERCEL_TOKEN`: a wrong
token gets a 403 from Vercel instead of "not logged in". The integration tests also pass inside
the image. Not tested: a run against real accounts.
