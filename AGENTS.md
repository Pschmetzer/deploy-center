# Notes for AI coding agents

Deploy Center is a public MIT repository: a SwiftUI Mac app (`app/`), a bash CLI (`deploys`, `lib/`, `providers/`),
integrations (`integrations/`), an iPhone app (`ios/`) and the website (`site/`). Read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Rules that are easy to break

- Nothing may start a build, a deploy or a rollback without an explicit click or a command with `--yes`. Tests use fakes and fixtures, never a real account.
- No real project names, team IDs, domains or paths in code, docs, tests or screenshots. Use made-up names.
- Texts the user sees are English and German: `L("English", "Deutsch")` in Swift. `scripts/check-strings.py` checks the pairs.
- The CLI stays bash 3.2 compatible (macOS). No `declare -A`, `mapfile` or `${x,,}`.
- Secrets never go on a command line, into a log or into the journal. Keys come from the keychain or the environment.
- Add a line under `## Unreleased` in `CHANGELOG.md` for anything a user would notice. Do not bump the version; `scripts/bump.sh` does.

## Build and test

```bash
bash tests/all.sh                         # every suite
./build.sh                                # the Mac app
python3 scripts/build-docs.py             # site/docs/ from docs/*.md (not committed)
python3 -I scripts/check-site.py          # the website: links, JSON-LD, titles
python3 -I scripts/check-links.py         # links in docs and site
python3 -I scripts/check-strings.py       # English and German texts
python3 -I scripts/check-release.py       # VERSION, website and appcast agree
```

CI runs the same plus shellcheck and actionlint (`.github/workflows/ci.yml`).

## Where things are

| What | Where |
| --- | --- |
| A host (Vercel, Render, Netlify ...) | `providers/<host>.sh`, contract in [docs/PROVIDERS.md](docs/PROVIDERS.md) |
| CLI commands | `deploys` (one file), shared helpers in `lib/` |
| Docs pages on the website | `docs/*.md`, listed in `scripts/build-docs.py` (`PAGES`) |
| Guides and the home page | `site/` (plain HTML and CSS, no build step) |
