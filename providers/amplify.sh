#!/bin/bash
# providers/amplify.sh: AWS Amplify Hosting for `deploys`. Opt-in, not a default provider.
#
# Contract (see the A1 change, "deploys: providers as files"): amplify_meta, _ready, _json, _has,
# _off, _deploy_json, _status, _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor.
# Extra commands that are Amplify's own (on) go through amplify_cmd.
#
# Sourced by `deploys`, or run on its own while the dispatcher does not route here yet:
#   bash providers/amplify.sh <command> [args]     (see amplify_cmd for the list)
#
# Access goes through the `aws` CLI, never hand-signed SigV4: the CLI already reads every way AWS
# credentials can be configured (profiles, SSO, assumed roles, env keys, credential_process),
# refreshes them, and retries throttled calls. Doing that in bash would be a second, weaker copy.
# See docs/providers/amplify.md.
#
# Which credentials: the profile in DEPLOYS_AMPLIFY_PROFILE, then AWS_PROFILE, then the profile
# name kept in the keychain item deploy-center-amplify (`deploys amplify set-key`, reads stdin),
# then the CLI's default chain. The keychain holds a profile NAME, never an access key.
# Region: AWS_REGION, then AWS_DEFAULT_REGION / the profile's region (the CLI reads those).
#
# A project is one app and its production branch: name = app name, id = "<appId>/<branch>".
# Commands take the id, the app id or the app name.
#
# shellcheck disable=SC2155  # `local x="$(...)"` is only used where the status does not matter.

AMPLIFY_KEYCHAIN="deploy-center-amplify"
CONFIG_DIR="${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"
USER="${USER:-$(id -un)}"
export AWS_PAGER=""

# What `deploys` itself defines, for when this file runs on its own.
declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# GNU first: on Linux `stat -f` means the file system and "succeeds" with the wrong answer.
amp_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# ---------- access ----------

# The profile to pass with --profile, or nothing for the CLI's own choice. Never fails.
amp_profile() {
  if [ -n "${DEPLOYS_AMPLIFY_PROFILE:-}" ]; then
    [ "$DEPLOYS_AMPLIFY_PROFILE" = default ] || printf '%s' "$DEPLOYS_AMPLIFY_PROFILE"; return 0
  fi
  [ -z "${AWS_PROFILE:-}" ] || return 0   # the CLI reads AWS_PROFILE itself
  local p=""
  if declare -F key_of >/dev/null; then p="$(key_of amplify 2>/dev/null)" || p=""; fi
  [ -n "$p" ] || p="$(security find-generic-password -a "$USER" -s "$AMPLIFY_KEYCHAIN" -w 2>/dev/null)" || p=""
  [ "$p" = default ] || printf '%s' "$p"
}
amp_profile_source() {
  if [ -n "${DEPLOYS_AMPLIFY_PROFILE:-}" ]; then echo environment
  elif [ -n "${AWS_PROFILE:-}" ]; then echo AWS_PROFILE
  elif security find-generic-password -a "$USER" -s "$AMPLIFY_KEYCHAIN" -w >/dev/null 2>&1; then echo keychain
  else echo none; fi
}

# amp_aws <service> <command> [args...]: the CLI, JSON on stdout. A failure dies with a hint.
amp_aws() {
  command -v aws >/dev/null 2>&1 || die "The aws CLI is not installed. brew install awscli (see docs/providers/amplify.md)"
  local prof args=() err out rc=0
  prof="$(amp_profile)"
  [ -z "$prof" ] || args+=(--profile "$prof")
  [ -z "${AWS_REGION:-}" ] || args+=(--region "$AWS_REGION")
  err="$(mktemp)"
  # ${args[@]+...}: an empty array is "unbound" under set -u in macOS bash 3.2.
  out="$(aws "$@" ${args[@]+"${args[@]}"} --output json 2>"$err")" || rc=$?
  if [ "$rc" != 0 ]; then
    local msg hint="" fix="deploys amplify set-key"
    [ -n "${DEPLOYS_AMPLIFY_PROFILE:-}${AWS_PROFILE:-}" ] && fix="check DEPLOYS_AMPLIFY_PROFILE / AWS_PROFILE"
    msg="$(grep -v '^[[:space:]]*$' "$err" | tail -n 3 | tr '\n' ' ' | head -c 400)"
    rm -f "$err"
    case "$msg" in
      *"specify a region"*) hint=" (no region: set AWS_REGION, or a region in the profile)";;
      *"Unable to locate credentials"*|*"could not be found"*|*"ProfileNotFound"*) hint=" (no AWS credentials: aws configure, aws sso login, or $fix)";;
      *ExpiredToken*|*"Token has expired"*|*"SSO session"*|*"sso login"*) hint=" (credentials expired: aws sso login${prof:+ --profile $prof})";;
      *AccessDenied*|*UnauthorizedException*|*UnrecognizedClient*|*InvalidClientTokenId*|*SignatureDoesNotMatch*) hint=" (the AWS identity may not use Amplify: it needs amplify:List*, Get*, UpdateBranch, StartJob, StopJob)";;
      *NotFoundException*) hint=" (not found: wrong region, renamed or deleted?)";;
      *LimitExceeded*|*TooManyRequests*|*Throttl*) hint=" (rate limit: try again in a minute)";;
      *"Could not connect"*|*"timed out"*|*EndpointConnectionError*) hint=" (no answer: network or timeout)";;
    esac
    die "AWS ${1:-} ${2:-} failed$hint: ${msg:-exit $rc}"
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# ---------- mapping ----------

# A job to one phase: queued|building|ready|failed|canceled. Times to epoch seconds.
AMP_JQ='def amp_phase: (.status // null) as $s
  | if $s == null then null
    elif $s == "RUNNING" then "building"
    elif $s == "SUCCEED" then "ready"
    elif $s == "FAILED" then "failed"
    elif ($s == "CANCELLING" or $s == "CANCELLED") then "canceled"
    else "queued" end;
  def amp_t: if . == null then null elif type == "number" then floor
    else (try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
      | (.d + "Z" | fromdateiso8601)
        - (if (.z // "Z") == "Z" then 0
           else (.z | (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end))
      catch null) // null end;
  def amp_msg: if . then split("\n")[0] else null end;
  def amp_job($b): {id:.jobId, phase:amp_phase, status, branch:$b, sha:(.commitId // null), msg:(.commitMessage | amp_msg),
    jobType:(.jobType // null), createdAt:((.startTime // .commitTime) | amp_t), endedAt:(.endTime | amp_t)};
  def amp_prod($app): ($app.productionBranch.branchName // null) as $pb
    | if $pb then $pb else ([.[] | select(.stage == "PRODUCTION") | .branchName][0] // (if length == 1 then .[0].branchName else null end)) end;
  def amp_region: (.appArn // "") | split(":") | .[3] // "";
  def amp_domain($b; $assoc): ([$assoc[]? as $d | $d.subDomains[]? | select(.subDomainSetting.branchName == $b)
      | (.subDomainSetting.prefix // "") as $p | (if $p == "" then $d.domainName else "\($p).\($d.domainName)" end)][0])
    // (if .defaultDomain then "\($b | gsub("/"; "-")).\(.defaultDomain)" else null end);
  def amp_dash($b): "https://\(amp_region).console.aws.amazon.com/amplify/apps/\(.appId)/branches/\($b | @uri)/deployments";'

# ---------- resolving a project ----------

amp_apps() { amp_aws amplify list-apps | jq -c '.apps // []'; }
amp_branches() { amp_aws amplify list-branches --app-id "$1" | jq -c '.branches // []'; }

# amp_resolve <project>: sets AMP_APP, AMP_BRANCH and AMP_APPJSON. Call it directly, not in $(...).
amp_resolve() {
  local p="${1:?project}" apps app n
  AMP_APP=""; AMP_BRANCH=""; AMP_APPJSON="{}"
  if [[ "$p" == */* ]]; then
    AMP_APP="${p%%/*}"; AMP_BRANCH="${p#*/}"
    AMP_APPJSON="$(amp_aws amplify get-app --app-id "$AMP_APP" | jq -c '.app')" || exit 1
    return 0
  fi
  apps="$(amp_apps)" || exit 1
  app="$(echo "$apps" | jq -c --arg p "$p" '[.[] | select(.appId == $p)] | if length == 0 then empty else .[0] end')"
  if [ -z "$app" ]; then
    n="$(echo "$apps" | jq --arg p "$p" '[.[] | select(.name == $p)] | length')"
    [ "$n" != 0 ] || die "Amplify: no app $p in this account and region (deploys amplify list)"
    if [ "$n" != 1 ]; then
      echo "$apps" | jq -r --arg p "$p" '.[] | select(.name == $p) | "  \(.appId)  \(.name)"' >&2
      die "Amplify: several apps are called $p. Use the id: <appId>/<branch>"
    fi
    app="$(echo "$apps" | jq -c --arg p "$p" '.[] | select(.name == $p)')"
  fi
  AMP_APPJSON="$app"; AMP_APP="$(echo "$app" | jq -r '.appId')"
  AMP_BRANCH="$(amp_branches "$AMP_APP" | jq -r --argjson app "$app" "$AMP_JQ"' amp_prod($app) // empty')" || exit 1
  [ -n "$AMP_BRANCH" ] || die "Amplify: $p has no production branch (and more than one branch). Use <appId>/<branch>"
}

amp_jobs() { amp_aws amplify list-jobs --app-id "$1" --branch-name "$2" --max-items "${3:-20}" | jq -c '.jobSummaries // []'; }

# ---------- the contract ----------

amplify_meta() {
  jq -n '{id:"amplify", label:"AWS Amplify Hosting", noun:"app", defaultOn:false,
    caps:{off:true, sha:true, cancel:true, rollback:true, logs:true, preview:true},
    keyEnv:["DEPLOYS_AMPLIFY_PROFILE"], keychain:"deploy-center-amplify", needs:"aws CLI",
    billing:"build minutes ($0.01 per minute on the standard build instance)"}'
}

# Ready when the aws CLI is there and Amplify was chosen: a profile in DEPLOYS_AMPLIFY_PROFILE or
# the keychain. AWS_PROFILE alone does not opt in: it is set for many other tools. Says nothing.
amplify_ready() {
  command -v aws >/dev/null 2>&1 || return 1
  [ -n "${DEPLOYS_AMPLIFY_PROFILE:-}" ] && return 0
  security find-generic-password -a "$USER" -s "$AMPLIFY_KEYCHAIN" -w >/dev/null 2>&1
}

amplify_has() {
  ( amp_resolve "$1" && amp_branches "$AMP_APP" | jq -e --arg b "$AMP_BRANCH" 'any(.[]; .branchName == $b)' ) >/dev/null 2>&1
}

# One app to one project. A failed read of its branches or jobs becomes fetchError, not a stop.
amp_project() {
  local app="$1" id branches jobs="[]" assoc="[]" err="" br
  id="$(echo "$app" | jq -r '.appId')"
  if ! branches="$( (amp_branches "$id") 2>&1)"; then err="${branches#Error: }"; branches="[]"; fi
  br="$(echo "$branches" | jq -r --argjson app "$app" "$AMP_JQ"' amp_prod($app) // empty' 2>/dev/null)"
  if [ -n "$br" ] && [ -z "$err" ]; then
    if ! jobs="$( (amp_jobs "$id" "$br") 2>&1)"; then err="${jobs#Error: }"; jobs="[]"; fi
    assoc="$( (amp_aws amplify list-domain-associations --app-id "$id" | jq -c '.domainAssociations // []') 2>/dev/null)" || assoc="[]"
  fi
  [ -n "$br" ] || [ -n "$err" ] || err="no production branch (and more than one branch)"
  echo "$app" | jq -c --arg b "$br" --argjson brs "$branches" --argjson jobs "$jobs" --argjson assoc "$assoc" --arg err "$err" "$AMP_JQ"'
    ($brs | map(select(.branchName == $b)) | .[0] // {}) as $branch
    | ($jobs[0] // null) as $new | ([$jobs[] | select(.status == "SUCCEED")][0] // {}) as $live
    | (if $b == "" then null else amp_domain($b; $assoc) end) as $dom
    | {name, id:(if $b == "" then .appId else "\(.appId)/\($b)" end),
       auto:($branch.enableAutoBuild == true),
       # Git-connected and the branch is known: StartJob RELEASE builds whether auto-build is on or not.
       deployable:(((.repository // "") != "") and $b != "" and $err == ""),
       paused:false,
       repo:((.repository // "") | if . == "" then null else sub("^https?://[^/]+/"; "") | sub("\\.git$"; "") end),
       ref:(if $b == "" then null else $b end),
       domain:$dom, url:(if $dom then "https://\($dom)" else null end),
       dashboardUrl:(if $b == "" then "https://\(amp_region).console.aws.amazon.com/amplify/apps/\(.appId)/overview" else amp_dash($b) end),
       lastAt:(($new // {}) | (.startTime // .commitTime) | amp_t), lastState:(($new // {}).status // null),
       lastSha:($live.commitId // null), lastMsg:($live.commitMessage | amp_msg),
       fetchError:(if $err == "" then null else $err end),
       phase:(if $new then ($new | amp_phase) else null end)}'
}

amplify_json() {
  local apps app out=()
  apps="$(amp_apps)" || exit 1
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    out+=("$(amp_project "$app")") || exit 1
  done < <(echo "$apps" | jq -c '.[]')
  [ "${#out[@]}" -gt 0 ] || { echo '[]'; return; }
  printf '%s\n' "${out[@]}" | jq -s 'sort_by(.name | ascii_downcase)'
}

amp_set_auto() {
  amp_aws amplify update-branch --app-id "$1" --branch-name "$2" "$3" | jq -r '.branch.enableAutoBuild'
}

# amplify_off <project> [--all]: auto-build off for the production branch; --all also for every
# other branch and for branches Amplify creates later.
amplify_off() {
  local p="$1" all="${2:-}" branches cur got others b
  amp_resolve "$p"
  branches="$(amp_branches "$AMP_APP")" || exit 1
  cur="$(echo "$branches" | jq -r --arg b "$AMP_BRANCH" '.[] | select(.branchName == $b) | .enableAutoBuild')"
  [ -n "$cur" ] || die "Amplify: $AMP_APP has no branch $AMP_BRANCH"
  if [ "$cur" = false ]; then echo "Amplify: $AMP_BRANCH of $p was already manual"
  else
    got="$(amp_set_auto "$AMP_APP" "$AMP_BRANCH" --no-enable-auto-build)" || exit 1
    [ "$got" = false ] || die "Amplify: asked to turn off auto-build for $AMP_BRANCH of $p, but it still shows it on"
    echo "Amplify: $AMP_BRANCH of $p no longer builds on push"
  fi
  others="$(echo "$branches" | jq -r --arg b "$AMP_BRANCH" '.[] | select(.branchName != $b and .enableAutoBuild == true) | .branchName')"
  if [ "$all" = --all ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      got="$(amp_set_auto "$AMP_APP" "$b" --no-enable-auto-build)" || exit 1
      echo "Amplify: $b of $p no longer builds on push"
    done <<< "$others"
    if [ "$(echo "$AMP_APPJSON" | jq '.enableBranchAutoBuild == true')" = true ]; then
      amp_aws amplify update-app --app-id "$AMP_APP" --no-enable-branch-auto-build >/dev/null || exit 1
      echo "Amplify: new branches of $p will not build on push"
    fi
  elif [ -n "$others" ]; then
    echo "Amplify: other branches of $p still build on push ($(echo "$others" | paste -sd, - | sed 's/,/, /g')). Add --all to turn those off too." >&2
  fi
}

amplify_on() {
  local got
  amp_resolve "$1"
  got="$(amp_set_auto "$AMP_APP" "$AMP_BRANCH" --enable-auto-build)" || exit 1
  [ "$got" = true ] || die "Amplify: asked to turn auto-build on for $AMP_BRANCH, but it still shows it off"
  echo "Amplify: $AMP_BRANCH of $1 builds on push again"
}

amp_lock() {
  if declare -F start_lock >/dev/null; then start_lock "$1"; return; fi
  local d="$CONFIG_DIR/locks" f; mkdir -p "$d"; f="$d/$(echo "$1" | tr '/ ' '__')"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(amp_mtime "$f") )) -ge 60 ]; then rm -f "$f"; fi
  ( set -C; : > "$f" ) 2>/dev/null || die "$1 is being started already (wait a minute)"
  echo "$f"
}

# amplify_deploy_json <project> [--sha <commit>] [--preview --branch <b>] [--message <m>]
# Prints {id, url, state, phase, branch, sha}. --preview builds another Amplify branch of the app.
amplify_deploy_json() {
  local p="$1" preview=0 branch="" sha="" msg="" lock out url
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview|preview) preview=1 ;;
      --branch) branch="${2:-}"; shift ;;
      --sha) sha="${2:-}"; shift ;;
      --message) msg="${2:-}"; shift ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <project> [--sha <commit>] [--preview --branch <b>]" ;;
    esac; shift
  done
  amp_resolve "$p"
  [ "$(echo "$AMP_APPJSON" | jq '(.repository // "") != ""')" = true ] \
    || die "Amplify: $p is not connected to Git (manual deploys): upload a build with create-deployment instead"
  if [ "$preview" = 1 ]; then
    [ -n "$branch" ] || die "A preview needs a branch other than $AMP_BRANCH: --branch <b>"
    [ "$branch" != "$AMP_BRANCH" ] || die "$AMP_BRANCH is the production branch; a preview needs another branch"
  fi
  [ -n "$branch" ] || branch="$AMP_BRANCH"
  if [ -n "$sha" ]; then [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "--sha wants a commit hash, got $sha"; fi
  local args=(--app-id "$AMP_APP" --branch-name "$branch" --job-type RELEASE --job-reason "Deploy Center")
  [ -z "$sha" ] || args+=(--commit-id "$sha" --commit-message "${msg:-Deploy $sha}")
  lock="$(amp_lock "amplify-$AMP_APP-$branch")" || exit 1
  out="$(amp_aws amplify start-job "${args[@]}")" || { rm -f "$lock"; exit 1; }
  url="$(amp_domain_of "$branch")"
  echo "$out" | jq --arg b "$branch" --arg u "$url" "$AMP_JQ"' .jobSummary | amp_job($b)
    | {id, url:(if $u == "" then null else "https://\($u)" end), state:.phase, phase, branch, sha}'
}

amplify_latest() {
  local jobs
  amp_resolve "$1"
  jobs="$(amp_jobs "$AMP_APP" "$AMP_BRANCH" 1)" || exit 1
  echo "$jobs" | jq -e --arg b "$AMP_BRANCH" "$AMP_JQ"' .[0] // empty | amp_job($b)' || die "Amplify: $1 has no builds yet"
}

# amplify_status <project> [<job id>]: one job (the newest without an id).
amplify_status() {
  [ -n "${2:-}" ] || { amplify_latest "$1"; return; }
  amp_resolve "$1"
  amp_aws amplify get-job --app-id "$AMP_APP" --branch-name "$AMP_BRANCH" --job-id "$2" \
    | jq --arg b "$AMP_BRANCH" "$AMP_JQ"' .job.summary | amp_job($b)'
}

# amplify_cancel <project> [<job id>]: stop the given job, or the newest one still running.
amplify_cancel() {
  local id="${2:-}" job
  amp_resolve "$1"
  if [ -z "$id" ]; then
    job="$(amp_jobs "$AMP_APP" "$AMP_BRANCH" 5 | jq -c --arg b "$AMP_BRANCH" "$AMP_JQ"'
      [.[] | amp_job($b) | select(.phase == "queued" or .phase == "building")][0] // empty')" || exit 1
    [ -n "$job" ] || die "Amplify: no build of $1 is running"
    id="$(echo "$job" | jq -r '.id')"
  fi
  amp_aws amplify stop-job --app-id "$AMP_APP" --branch-name "$AMP_BRANCH" --job-id "$id" \
    | jq --arg b "$AMP_BRANCH" "$AMP_JQ"' .jobSummary | amp_job($b) | {id, state:.phase, phase, branch, sha}'
}

# amplify_rollback <project> [<job id>|<sha>]: build an earlier commit again. Without a target,
# the newest succeeded commit before the live one (a different commit, so it really changes).
# Amplify has no instant rollback for Git builds: this is a new build and costs build minutes.
amplify_rollback() {
  local p="$1" target="${2:-}" jobs pick
  amp_resolve "$p"
  jobs="$(amp_jobs "$AMP_APP" "$AMP_BRANCH" 50)" || exit 1
  pick="$(echo "$jobs" | jq -c --arg t "$target" '
    [.[] | select(.status == "SUCCEED" and (.commitId // "") != "")] as $ok
    | if $t == "" then
        ($ok[0].commitId // null) as $live | [$ok[] | select(.commitId != $live)][0] // empty
      else [.[] | select(.jobId == $t or ((.commitId // "") | startswith($t)) and $t != "")][0] // empty end')"
  if [ -z "$pick" ]; then
    [ -n "$target" ] && [[ "$target" =~ ^[0-9a-fA-F]{7,40}$ ]] && pick="{\"commitId\":\"$target\"}"
    [ -n "$pick" ] || die "Amplify: ${target:+no build $target of $p, and }no earlier good commit of $p to go back to"
  fi
  local sha msg
  sha="$(echo "$pick" | jq -r '.commitId // empty')"
  [ -n "$sha" ] && [ "$sha" != HEAD ] || die "Amplify: build ${target:-?} of $p has no commit to rebuild"
  msg="$(echo "$pick" | jq -r '.commitMessage // "" | split("\n")[0]')"
  echo "Amplify: rebuilding $p at ${sha:0:7}${msg:+ ($msg)}" >&2
  amplify_deploy_json "$AMP_APP/$AMP_BRANCH" --sha "$sha" --message "Rollback to ${sha:0:7}${msg:+: $msg}"
}

# amplify_logs <project> [lines] [<job id>]: every step's log (logUrl, a short-lived S3 link that
# is never printed), each line prefixed with its step, the last <lines> of them.
amplify_logs() {
  local p="$1" n="${2:-60}" id="${3:-}" job step url out
  amp_resolve "$p"
  [ -n "$id" ] || id="$(amp_jobs "$AMP_APP" "$AMP_BRANCH" 1 | jq -r '.[0].jobId // empty')" || exit 1
  [ -n "$id" ] || die "Amplify: $p has no builds yet"
  job="$(amp_aws amplify get-job --app-id "$AMP_APP" --branch-name "$AMP_BRANCH" --job-id "$id")" || exit 1
  {
    while IFS=$'\t' read -r step url; do
      [ -n "$url" ] || continue
      if out="$(curl -sSf --connect-timeout 10 --max-time 60 "$url" 2>/dev/null)"; then
        printf '%s\n' "$out" | awk -v s="$step" '{print s "  " $0}'
      else
        echo "$step  (log could not be read; the link may have expired: run logs again)"
      fi
    done < <(echo "$job" | jq -r '.job.steps[]? | [(.stepName // "STEP"), (.logUrl // "")] | @tsv')
  } | tail -n "$n"
}

# amp_domain_of <branch>: its custom domain, else <branch>.<default domain>. After amp_resolve.
amp_domain_of() {
  local assoc
  assoc="$( (amp_aws amplify list-domain-associations --app-id "$AMP_APP" | jq -c '.domainAssociations // []') 2>/dev/null)" || assoc="[]"
  echo "$AMP_APPJSON" | jq -r --arg b "$1" --argjson a "${assoc:-[]}" "$AMP_JQ"' amp_domain($b; $a) // empty'
}

# amplify_url <project> [--dashboard]
amplify_url() {
  local d
  amp_resolve "$1"
  if [ "${2:-}" = --dashboard ]; then echo "$AMP_APPJSON" | jq -r --arg b "$AMP_BRANCH" "$AMP_JQ"' amp_dash($b)'; return; fi
  d="$(amp_domain_of "$AMP_BRANCH")"
  [ -n "$d" ] || die "Amplify: $1 has no domain yet"
  echo "https://$d"
}

# The name of an AWS CLI profile from stdin ("default" for the default chain), tried first, kept in
# the keychain only when it works. AWS keys themselves stay with the CLI.
amplify_set_key() {
  local prof who
  IFS= read -r prof || true
  prof="$(printf '%s' "$prof" | tr -d '[:space:]')"
  [ -n "$prof" ] || die "Pipe in an AWS CLI profile name: echo my-profile | deploys amplify set-key (or \"default\")"
  [[ "$prof" =~ ^[A-Za-z0-9._@+=,-]+$ ]] || die "That does not look like a profile name. AWS keys go into aws configure, not here"
  [[ "$prof" =~ ^(AKIA|ASIA)[A-Z0-9]{12,}$ ]] && die "That is an access key, not a profile name. Run aws configure --profile <name>, then set-key <name>"
  who="$(DEPLOYS_AMPLIFY_PROFILE="$prof" amp_aws sts get-caller-identity 2>&1 | jq -r '.Arn // empty' 2>/dev/null)" || who=""
  [ -n "$who" ] || die "The aws CLI could not sign in with profile $prof; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "$USER" "$AMPLIFY_KEYCHAIN" "$prof" | security -i >/dev/null \
    || die "The profile works, but could not be saved in the keychain"
  echo "Amplify: profile $prof saved and working ($who)."
}

amplify_doctor() {
  local cli=false ver="" src prof region="" arn="" valid=false
  if command -v aws >/dev/null 2>&1; then
    cli=true; ver="$(aws --version 2>&1 | head -n 1 | awk '{print $1}')"
    src="$(amp_profile_source)"; prof="$(amp_profile)"
    region="${AWS_REGION:-$(aws configure get region ${prof:+--profile "$prof"} 2>/dev/null)}" || region=""
    arn="$( (amp_aws sts get-caller-identity | jq -r '.Arn // empty') 2>/dev/null)" && [ -n "$arn" ] && valid=true
  else src="$(amp_profile_source)"; prof="$(amp_profile)"; fi
  jq -nc --argjson cli "$cli" --arg ver "$ver" --arg src "$src" --arg prof "$prof" --arg region "$region" \
    --arg arn "$arn" --argjson valid "$valid" --argjson ready "$(amplify_ready && echo true || echo false)" '
    {provider:"amplify", cli:$cli, cliVersion:(if $ver == "" then null else $ver end),
     profile:(if $prof == "" then null else $prof end), profileSource:$src,
     region:(if $region == "" then null else $region end), identity:(if $arn == "" then null else $arn end),
     credentialsValid:$valid, enabled:$ready,
     note:(if $cli | not then "install the aws CLI: brew install awscli"
           elif $valid | not then "the aws CLI cannot sign in: aws configure / aws sso login, then deploys amplify set-key <profile>"
           elif $region == "" then "no region: set AWS_REGION or a region in the profile"
           elif $ready | not then "works, but not turned on: echo <profile> | deploys amplify set-key, or DEPLOYS_AMPLIFY_PROFILE"
           else "ready" end)}'
}

# ---------- commands ----------

amplify_cmd() {
  local c="${1:-}"; shift || true
  case "$c" in
    meta) amplify_meta ;;
    json|list) amplify_json ;;
    has) amplify_has "${1:?project}" ;;
    off|autodeploy-off) amplify_off "${1:?project}" "${2:-}" ;;
    on|autodeploy-on) amplify_on "${1:?project}" ;;
    deploy-json|deploy) amplify_deploy_json "${1:?project}" "${@:2}" ;;
    status) amplify_status "${1:?project}" "${2:-}" ;;
    latest) amplify_latest "${1:?project}" ;;
    cancel) amplify_cancel "${1:?project}" "${2:-}" ;;
    rollback) amplify_rollback "${1:?project}" "${2:-}" ;;
    logs) amplify_logs "${1:?project}" "${2:-60}" "${3:-}" ;;
    url|open) amplify_url "${1:?project}" "${2:-}" ;;
    set-key) amplify_set_key ;;
    doctor) amplify_doctor ;;
    ready) amplify_ready ;;
    *) die "Usage: deploys amplify meta|list|has|off [--all]|on|deploy|deploy-json|status|latest|cancel|rollback|logs|url|set-key|doctor" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  amplify_cmd "$@"
fi
