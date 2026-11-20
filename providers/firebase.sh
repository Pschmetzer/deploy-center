#!/bin/bash
# providers/firebase.sh — the Firebase Hosting provider for `deploys` (opt-in: deploys providers enable firebase).
#
# Firebase Hosting has no build service: `firebase deploy` (or your CI) uploads the files and
# makes a new version live. What the Hosting REST API can do from here is read the sites, their
# live releases and versions, and make an existing version live again. So:
#   deploy    = release the newest finished version that is not live (roll forward, e.g. after a rollback)
#   rollback  = release the version that was live before
# It never uploads files and builds nothing (docs/providers/firebase.md).
#
# Contract (docs/PROVIDERS.md): firebase_meta, _ready, _json, _has, _off, _deploy_json, _status,
# _latest, _cancel, _rollback, _logs, _url, _set_key, _doctor. Phases: queued | building | ready | failed | canceled.
# A deploy id is a release id of the live channel.
#
# Access token: FIREBASE_ACCESS_TOKEN or GOOGLE_OAUTH_ACCESS_TOKEN (OAuth, valid for an hour), or a
# command that prints one: FIREBASE_ACCESS_TOKEN_CMD='gcloud auth print-access-token' (deploys asks it
# each time, so nothing expires), else the keychain item deploy-center-firebase. It goes to curl on stdin.
# Project: FIREBASE_PROJECT, else "project" in <config>/firebase.json.

FIREBASE_KEYCHAIN="deploy-center-firebase"
FIREBASE_API="${FIREBASE_API:-https://firebasehosting.googleapis.com/v1beta1}"

declare -F die >/dev/null || die() { echo "Error: $*" >&2; exit 1; }
# shellcheck source=../lib/http.sh
declare -F http_call >/dev/null || { _fb_h="$(dirname "${BASH_SOURCE[0]}")/../lib/http.sh"; [ ! -f "$_fb_h" ] || . "$_fb_h"; unset _fb_h; }

firebase_config_dir() { echo "${CONFIG_DIR:-${DEPLOYS_CONFIG:-$HOME/.config/deploys}}"; }

firebase_key() {
  local k=""
  if declare -F key_of >/dev/null; then k="$(key_of firebase 2>/dev/null)" || k=""
  elif [ -n "${FIREBASE_ACCESS_TOKEN:-}" ]; then k="$FIREBASE_ACCESS_TOKEN"
  elif [ -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]; then k="$GOOGLE_OAUTH_ACCESS_TOKEN"
  else k="$(security find-generic-password -a "${USER:-$(id -un)}" -s "$FIREBASE_KEYCHAIN" -w 2>/dev/null)" || k=""
  fi
  [ -n "$k" ] || { echo "No Firebase access token. Set FIREBASE_ACCESS_TOKEN_CMD='gcloud auth print-access-token' (or FIREBASE_ACCESS_TOKEN), or: gcloud auth print-access-token | deploys firebase set-key" >&2; return 1; }
  printf '%s' "$k"
}

# The Google Cloud / Firebase project id: lowercase letters, digits and dashes.
firebase_project() {
  local p="${FIREBASE_PROJECT:-}" f
  if [ -z "$p" ]; then f="$(firebase_config_dir)/firebase.json"; [ ! -f "$f" ] || p="$(jq -r '.project // empty' "$f" 2>/dev/null)"; fi
  [ -n "$p" ] || { echo "No Firebase project. Set FIREBASE_PROJECT=<project id> (or put {\"project\":\"<id>\"} in $(firebase_config_dir)/firebase.json)" >&2; return 1; }
  case "$p" in *[!a-z0-9-]*) echo "Firebase: \"$p\" is not a project id" >&2; return 1 ;; esac
  printf '%s' "$p"
}

firebase_valid() { case "$1" in ''|-*|*[!A-Za-z0-9_-]*) return 1 ;; esac; }

# firebase_call METHOD PATH: the answer on stdout; on failure the reason on stderr, rc 1.
firebase_call() {
  local k e rc=0 fix="refresh the token: gcloud auth print-access-token | deploys firebase set-key (it lasts an hour; FIREBASE_ACCESS_TOKEN_CMD avoids that)"
  declare -F http_call >/dev/null || { echo "Firebase: lib/http.sh is missing" >&2; return 1; }
  k="$(firebase_key)" || return 1
  # shellcheck disable=SC2034  # read by http_call
  local HTTP_AUTH="Authorization: Bearer $k" HTTP_FIX="$fix"
  e="$(mktemp)"
  ( http_call "Firebase" "$1" "$FIREBASE_API$2" "${3:-}" ) 2>"$e" || rc=$?
  [ "$rc" = 0 ] || sed '1s/^[^ ]*Error:[^ ]* //' "$e" >&2
  rm -f "$e"; return "$rc"
}

# shellcheck disable=SC2016
FIREBASE_JQ='
  def t: (. // null) | if . then (sub("\\.[0-9]+Z$";"Z") | try fromdateiso8601 catch null) else null end;
  def phase: if . == null then null
    elif test("^(CREATED|CLONING)$") then "building"
    elif . == "FINALIZED" then "ready"
    elif . == "ABANDONED" then "failed"
    elif test("^(DELETED|EXPIRED)$") then "canceled"
    else null end;
  def sid: (.name // "") | split("/") | last;
  def rid: (.name // "") | split("/") | last;
  def line: if . == null then "none\t\t?" else "\(rid)\t\(.version.status | phase // "")\t\(.version.status // "?")" end;
'

firebase_meta() {
  printf '{"id":"firebase","label":"Firebase Hosting","noun":"site","defaultOn":false,"keyEnv":["FIREBASE_ACCESS_TOKEN","GOOGLE_OAUTH_ACCESS_TOKEN"],"keychain":"%s","caps":{"off":false,"sha":false,"cancel":false,"rollback":true,"logs":false,"preview":false}}\n' "$FIREBASE_KEYCHAIN"
}

firebase_ready() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && firebase_project >/dev/null 2>&1 && firebase_key >/dev/null 2>&1; }

firebase_sites() {
  local p out
  p="$(firebase_project)" || return 1
  out="$(firebase_call GET "/projects/$p/sites?pageSize=100")" || return 1
  printf '%s' "$out" | jq -e '(.sites // []) | type == "array"' >/dev/null 2>&1 || { echo "Firebase answered without a site list" >&2; return 1; }
  printf '%s' "$out"
}

# The newest releases of the live channel of a site, newest first, as a JSON array.
firebase_releases() {  # firebase_releases <site> [n]
  local out
  firebase_valid "$1" || { echo "Firebase: \"$1\" is not a site id" >&2; return 1; }
  out="$(firebase_call GET "/sites/$1/channels/live/releases?pageSize=${2:-5}")" || return 1
  printf '%s' "$out" | jq -ce '(.releases // []) | select(type == "array")' || { echo "Firebase answered without a release list for $1" >&2; return 1; }
}

firebase_has() {
  local id
  firebase_valid "$1" || return 1
  id="$(firebase_sites 2>/dev/null | jq -r --arg n "$1" "$FIREBASE_JQ"'(.sites // [])[] | select(sid == $n) | sid' | head -n 1)"
  [ -n "$id" ] && printf '%s\n' "$id"
}

firebase_json() {
  local sites p s rel rows="" row
  p="$(firebase_project)" || die "Firebase: no project"
  sites="$(firebase_sites)" || die "Could not list Firebase Hosting sites"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if rel="$(firebase_releases "$s" 5 2>&1)"; then row="$(jq -nc --arg s "$s" --argjson r "$rel" '{site:$s, rel:$r}')"
    else row="$(jq -nc --arg s "$s" --arg e "$rel" '{site:$s, rel:[], err:$e}')"; fi
    rows="$rows$row"$'\n'
  done < <(printf '%s' "$sites" | jq -r "$FIREBASE_JQ"'(.sites // [])[] | sid')
  jq -n --argjson sites "$sites" --arg p "$p" --slurpfile rows <(printf '%s' "$rows") "$FIREBASE_JQ"'
    ($rows | map({(.site): .}) | add // {}) as $by
    | [($sites.sites // [])[] | . as $s | ($s | sid) as $id | ($by[$id] // {rel:[]}) as $x | ($x.rel[0] // {}) as $new
      | {name:$id, id:$id, auto:false, deployable:true, paused:false, repo:null, ref:null,
         domain:(($s.defaultUrl // "") | sub("^https?://";"") | sub("/.*$";"") | if . == "" then null else . end),
         url:($s.defaultUrl // null),
         dashboardUrl:("https://console.firebase.google.com/project/" + $p + "/hosting/sites/" + $id),
         lastAt:(($new.releaseTime // $new.version.createTime) | t), lastState:($new.version.status // null),
         lastSha:null, lastMsg:($new.message // null),
         fetchError:($x.err // null), phase:(if $x.err then null else ($new.version.status | phase) end),
         releaseType:($new.type // null)}]
    | sort_by(.name | ascii_downcase)'
}

firebase_off() { die "Firebase Hosting cannot turn auto-deploy off: it deploys only when you or your CI run \`firebase deploy\`"; }
firebase_cancel() { die "Firebase Hosting cannot cancel a release from here"; }
firebase_logs() { die "Firebase Hosting cannot show logs from here: the deploy log is in your CI or \`firebase deploy\`"; }

# Make a version live: POST to the releases of the live channel.
firebase_release() {  # firebase_release <site> <version name: sites/<s>/versions/<v>>
  firebase_call POST "/sites/$1/channels/live/releases?versionName=$2"
}

# The newest finished version of a site that is not the live one.
firebase_deploy_json() {
  local site="${1:-}" lock="" live vs new out
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) die "Firebase Hosting cannot deploy a preview from here: preview channels are made with \`firebase hosting:channel:deploy\`" ;;
      --sha) die "Firebase Hosting cannot deploy a given commit from here: it releases a version that already exists" ;;
      --no-cache) die "Firebase Hosting cannot build: it releases a version that already exists" ;;
      "") ;;
      *) die "Unknown option $1. Usage: deploy-json <site>" ;;
    esac; shift
  done
  firebase_valid "$site" || die "Firebase: \"$site\" is not a site id"
  if declare -F start_lock >/dev/null; then lock="$(start_lock "firebase-$site")" || exit 1; fi
  live="$(firebase_releases "$site" 1 | jq -r '.[0].version.name // empty')" || { rm -f "$lock"; die "Firebase: could not read the live release of $site"; }
  vs="$(firebase_call GET "/sites/$site/versions?pageSize=25")" || { rm -f "$lock"; die "Firebase: could not read the versions of $site"; }
  # Only a finished version that is newer than the live one counts: after a rollback, the one that was live before.
  new="$(printf '%s' "$vs" | jq -r --arg l "$live" '(.versions // []) as $v | (([$v[] | select(.name == $l) | .createTime][0]) // "") as $lt
      | [$v[] | select(.status == "FINALIZED" and .name != $l and (.createTime // "") > $lt)] | sort_by(.createTime) | last.name // empty' 2>/dev/null)" \
    || { rm -f "$lock"; die "Firebase answered without a version list for $site"; }
  [ -n "$new" ] || { rm -f "$lock"; die "Firebase: $site has no finished version newer than the live one; nothing to roll forward to (upload with \`firebase deploy\`)"; }
  out="$(firebase_release "$site" "$new")" || { rm -f "$lock"; die "Firebase did not release $new for $site"; }
  printf '%s' "$out" | jq -ce --arg u "https://$site.web.app" "$FIREBASE_JQ"'select(type == "object" and (.name // "") != "")
    | {id:rid, url:$u, state:(.version.status // "CLONING"), phase:((.version.status // "CLONING") | phase)}' \
    || die "Firebase answered without a release for $site"
}

firebase_status() {
  local site="$1" d="${2:-}" r
  firebase_valid "$site" && firebase_valid "$d" || die "Usage: status <site> <release id>"
  r="$(firebase_call GET "/sites/$site/channels/live/releases/$d")" || die "Firebase: could not read release $d"
  printf '%s' "$r" | jq -e 'type == "object" and ((.name // "") != "")' >/dev/null 2>&1 || die "Firebase answered without a release for $d"
  printf '%s\n' "$r" | jq -r "$FIREBASE_JQ"'line'
}
firebase_cli_status() { firebase_call GET "/sites/$1/channels/live/releases/$2"; }

firebase_latest() {
  local rel
  rel="$(firebase_releases "$1" 1)" || die "Firebase: could not read the releases of $1"
  printf '%s' "$rel" | jq -r "$FIREBASE_JQ"'.[0] // null | line'
}
firebase_cli_latest() { firebase_releases "$1" 1 | jq '.[0] // null'; }

# Back to the version that was live before: the next older release with another finished version.
firebase_rollback() {
  local site="$1" rel target out
  rel="$(firebase_releases "$site" 10)" || die "Firebase: could not read the releases of $site"
  target="$(printf '%s' "$rel" | jq -r '(.[0].version.name // "") as $live | [.[1:][] | select(.version.name != $live and .version.status == "FINALIZED")][0].version.name // empty')"
  [ -n "$target" ] || die "Firebase: $site has no earlier version to go back to"
  out="$(firebase_release "$site" "$target")" || die "Firebase did not roll $site back"
  printf '%s' "$out" | jq -ce --arg t "${target##*/}" "$FIREBASE_JQ"'select(type == "object" and (.name // "") != "")
    | {id:rid, state:(.version.status // "CLONING"), phase:((.version.status // "CLONING") | phase), message:"Firebase: going back to version \($t)"}' \
    || die "Firebase answered without a release for the rollback"
}

firebase_url() {
  local u
  firebase_valid "$1" || die "Firebase: \"$1\" is not a site id"
  if [ "${2:-}" = --dashboard ]; then echo "https://console.firebase.google.com/project/$(firebase_project)/hosting/sites/$1"; return 0; fi
  u="$(firebase_sites | jq -r --arg n "$1" "$FIREBASE_JQ"'(.sites // [])[] | select(sid == $n) | .defaultUrl // empty' | head -n 1)" || die "Firebase: could not read $1"
  echo "${u:-https://$1.web.app}"
}

firebase_setup_hint() { echo "export FIREBASE_PROJECT=<project id> and FIREBASE_ACCESS_TOKEN_CMD='gcloud auth print-access-token'"; }

firebase_set_key() {
  local key=""
  if [ -t 0 ]; then IFS= read -rs key || true; echo >&2; else IFS= read -r key || true; fi
  key="$(printf "%s" "$key" | tr -d "\r" | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$key" ] || die "Pipe the token in: gcloud auth print-access-token | deploys firebase set-key"
  case "$key" in *\'*|*\"*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) die "That does not look like an access token" ;; esac
  firebase_project >/dev/null || die "Set the project first: export FIREBASE_PROJECT=<project id>"
  ( FIREBASE_ACCESS_TOKEN="$key"; key_of() { printf '%s' "$FIREBASE_ACCESS_TOKEN"; }; firebase_sites >/dev/null ) || die "Firebase did not accept that token; nothing was saved"
  printf 'add-generic-password -U -a %s -s %s -w %s\n' "${USER:-$(id -un)}" "$FIREBASE_KEYCHAIN" "$key" | security -i >/dev/null \
    || die "The token works, but could not be saved in the keychain"
  echo "Firebase access token saved and working (it lasts about an hour; FIREBASE_ACCESS_TOKEN_CMD asks for a fresh one each time)."
}

firebase_doctor() {
  local src="missing" ok=false err="" n=null e p=""
  p="$(firebase_project 2>/dev/null)" || p=""
  if [ -n "${FIREBASE_ACCESS_TOKEN:-}" ] || [ -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]; then src="env"
  elif [ -n "${FIREBASE_ACCESS_TOKEN_CMD:-}" ] || [ -n "${GOOGLE_OAUTH_ACCESS_TOKEN_CMD:-}" ]; then src="command"
  elif security find-generic-password -a "${USER:-$(id -un)}" -s "$FIREBASE_KEYCHAIN" >/dev/null 2>&1; then src="keychain"; fi
  if [ "$src" != missing ] && [ -n "$p" ]; then
    e="$(mktemp)"
    if n="$(firebase_sites 2>"$e" | jq '(.sites // []) | length' 2>/dev/null)" && [ -n "$n" ]; then ok=true; else n=null; err="$(tail -n 1 "$e")"; fi
    rm -f "$e"
  fi
  jq -n --arg src "$src" --argjson ok "$ok" --arg err "$err" --argjson n "${n:-null}" --arg p "$p" \
    '{provider:"firebase", key:$src, keyOk:$ok, project:(if $p == "" then null else $p end),
      error:(if $err == "" then null else $err end), sites:$n, expiresAt:null, rateLimit:null}'
}
