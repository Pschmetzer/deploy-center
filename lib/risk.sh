# shellcheck shell=bash
# lib/risk.sh - the risk rules (RISK_DEF, a jq program: which files of a pending diff make a deploy yellow or red) and
# hook_run (the hooks.d scripts around a deploy), moved out of the script. Sourced by deploys; hook_run uses its
# helpers (with_timeout, journal_add) and CONFIG_DIR.

# One list of "files that change how it runs" (re_*), used by risk and by details .risky.
# What a pending diff touches, from a GitHub comparison (its .files): migrations are red, lockfiles,
# environment files and config yellow, a large diff yellow and a very large one red. The worst wins.
# Each reason has a kind, so the app can say it in its own language.
# shellcheck disable=SC2089,SC2090  # a jq program, handed to jq as one argument
RISK_DEF='def re_mig: "(^|/)(migrations?|migrate|prisma|drizzle|alembic|flyway|liquibase)/|(^|/)db/seeds?(/|\\.rb$)|(^|/)[0-9]+[_-][^/]*\\.sql$|(^|/)(schema\\.(prisma|rb)|atlas\\.hcl|structure\\.dump)$";
  def re_lock: "(^|/)(package-lock\\.json|npm-shrinkwrap\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb?|Pipfile\\.lock|poetry\\.lock|uv\\.lock|Gemfile\\.lock|Cargo\\.lock|go\\.sum|composer\\.lock|pdm\\.lock|mix\\.lock|pubspec\\.lock|Package\\.resolved|deno\\.lock|package\\.json|requirements\\.txt|go\\.mod|pyproject\\.toml|Pipfile|Gemfile|composer\\.json|Cargo\\.toml|build\\.gradle(\\.kts)?|pom\\.xml|pnpm-workspace\\.yaml|\\.npmrc|bunfig\\.toml)$";
  def re_runtime: "(^|/)(\\.nvmrc|\\.node-version|\\.python-version|\\.tool-versions|runtime\\.txt|\\.ruby-version)$";
  def re_gen: "(^|/)(package-lock\\.json|npm-shrinkwrap\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb?|Pipfile\\.lock|poetry\\.lock|uv\\.lock|Gemfile\\.lock|Cargo\\.lock|go\\.sum|composer\\.lock|pdm\\.lock|mix\\.lock|pubspec\\.lock|Package\\.resolved|deno\\.lock)$|\\.snap$|(^|/)__generated__/|\\.min\\.[a-z]+$";
  def re_env: "(^|/)\\.env($|\\.(?!(example|sample|template|dist)$))";
  def re_cfg: "\\.sql$|(^|/)(vercel\\.json|render\\.yaml|Dockerfile|docker-compose\\.ya?ml|Procfile|(next|vite|nuxt|astro|svelte|remix)\\.config\\.[a-z]+|netlify\\.toml|_redirects|_headers|wrangler\\.(toml|jsonc?)|amplify\\.yml|nixpacks\\.toml|fly\\.toml|railway\\.(json|toml)|firebase\\.json|app\\.yaml|serverless\\.yml|Makefile|\\.gitlab-ci\\.yml)$|^\\.do/app\\.yaml$|^\\.github/(workflows|actions)/";
  def risky_files: [(.files // [])[] | .filename | select(test(re_mig) or test(re_lock) or test(re_runtime) or test(re_env) or test(re_cfg))];
  def risk:
  [(.files // [])[] | .filename] as $f
  | def hits(re): [$f[] | select(test(re))];
    def some(fs): fs[0:3] | join(", ") + (if (fs | length) > 3 then " and \((fs | length) - 3) more" else "" end);
  hits(re_mig) as $mig
  | hits(re_lock) as $lock
  | hits(re_env) as $env
  | hits(re_cfg) as $cfg
  | hits(re_runtime) as $rt
  # Lockfiles, snapshots and generated code have their own note: they do not make a diff "very large".
  | ([(.files // [])[] | select(.filename | test(re_gen) | not) | (.additions // 0) + (.deletions // 0)] | add // 0) as $sized
  | ([(.files // [])[] | (.additions // 0) + (.deletions // 0)] | add // 0) as $lines
  | ($f | length) as $n
  | [ (if ($mig | length) > 0 then {kind:"migrations", level:"red", files:$mig[0:10], text:"database migrations: \(some($mig))"} else empty end),
      (if ($lock | length) > 0 then {kind:"lockfile", level:"yellow", files:$lock[0:10], text:"dependencies changed: \(some($lock))"} else empty end),
      (if ($rt | length) > 0 then {kind:"runtime", level:"yellow", files:$rt[0:10], text:"runtime version changed: \(some($rt))"} else empty end),
      (if ($env | length) > 0 then {kind:"env", level:"yellow", files:$env[0:10], text:"environment files: \(some($env))"} else empty end),
      (if ($cfg | length) > 0 then {kind:"config", level:"yellow", files:$cfg[0:10], text:"build or platform config: \(some($cfg))"} else empty end),
      (if $sized > 3000 or $n >= 100 then {kind:"size", level:"red", files:[], text:"a very large diff: \($n) files, \($sized) lines"}
       elif $sized > 500 or $n > 30 then {kind:"size", level:"yellow", files:[], text:"a large diff: \($n) files, \($sized) lines"} else empty end) ] as $r
  | {level:(if any($r[]; .level == "red") then "red" elif ($r | length) > 0 then "yellow" else "green" end),
     reasons:$r, files:$n, lines:$lines,
     # GitHub lists 300 files of a comparison at most: from there the picture is a floor, not the whole diff.
     partial:($n >= 300)};'
# shellcheck disable=SC2090
export RISK_DEF

# hooks.d: executable files named pre-deploy* or post-deploy* in $CONFIG_DIR/hooks.d, run around a start with
# DEPLOYS_PLATFORM, DEPLOYS_PROJECT, DEPLOYS_SHA (and DEPLOYS_STATE after). A pre-deploy hook that exits non-zero
# stops that start; a post-deploy hook cannot. A file that others or the group can write to, or that another account owns
# (root excepted), is never run. A hook that runs longer than DEPLOYS_HOOK_TIMEOUT seconds (default 300, 0 = no limit)
# is stopped and counts as failed. Their output goes to stderr.
hook_run() {  # hook_run <pre-deploy|post-deploy> <platform> <name> [<sha>] [<state>]
  local d="$CONFIG_DIR/hooks.d" h perm rc owner me hto="${DEPLOYS_HOOK_TIMEOUT:-300}"
  [ -d "$d" ] || return 0
  me="$(id -un 2>/dev/null)"
  local dperm; dperm="$(ls -ldH "$d" | cut -c1-10)"
  if [ "${dperm:5:1}" = w ] || [ "${dperm:8:1}" = w ]; then echo "hooks.d: the folder is writable by its group or by everyone; no hook was run (chmod go-w $d)" >&2; return 0; fi
  for h in "$d/$1"*; do
    # Backups and editor files are no hooks (pre-deploy.bak, pre-deploy.sh~), and a link may point anywhere.
    case "$h" in *'~'|*.bak|*.orig|*.swp|*.disabled|*.dpkg-*|*.rpmsave|*.rpmnew) continue ;; esac
    if [ -L "$h" ]; then echo "hooks.d: $(basename "$h") is a symbolic link and was not run" >&2; continue; fi
    [ -f "$h" ] && [ -x "$h" ] || continue
    perm="$(ls -ld "$h" | cut -c1-10)"
    if [ "${perm:8:1}" = w ]; then echo "hooks.d: $(basename "$h") is writable by everyone and was not run (chmod o-w)" >&2; continue; fi
    if [ "${perm:5:1}" = w ]; then echo "hooks.d: $(basename "$h") is writable by its group and was not run (chmod g-w)" >&2; continue; fi
    owner="$(ls -ld "$h" | awk '{print $3}')"
    if [ -n "$me" ] && [ "$owner" != "$me" ] && [ "$owner" != root ]; then echo "hooks.d: $(basename "$h") belongs to $owner, not to you, and was not run" >&2; continue; fi
    rc=0
    DEPLOYS_HOOK="$1" DEPLOYS_PLATFORM="$2" DEPLOYS_PROJECT="$3" DEPLOYS_SHA="${4:-}" DEPLOYS_STATE="${5:-}" with_timeout "$hto" "$h" </dev/null >&2 || rc=$?
    if [ "$rc" != 0 ]; then
      case "$rc" in 124|142) echo "hooks.d: $(basename "$h") ran longer than ${hto}s (DEPLOYS_HOOK_TIMEOUT) and was stopped" >&2 ;; *) echo "hooks.d: $(basename "$h") exited $rc" >&2 ;; esac
      [ "$1" != pre-deploy ] || return 1
    fi
  done
  return 0
}
