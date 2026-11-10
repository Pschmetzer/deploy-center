#!/bin/bash
# The provider contract (docs/PROVIDERS.md), checked for every providers/<p>.sh from its fixtures
# in tests/fixtures/<p>/: the functions exist, _meta is valid, _json has every field and a phase
# from the enum, status/latest/deploy_json answer in shape, a missing capability is refused.
# Then switching providers on and off. No network: PATH holds only stand-ins and /usr/bin:/bin.
# Run: tests/providers/contract.sh (tests/script-tests.sh runs it too).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
root="$PWD"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp tests/lib/fake-curl.sh "$tmp/bin/curl"; cp tests/lib/fake-vercel.sh "$tmp/bin/vercel"
printf '#!/bin/bash\nexit 44\n' > "$tmp/bin/security"   # no keychain entry
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin"/*
export FIXTURES="$root/tests/fixtures" CALLS="$tmp/calls.log"
STUBPATH="$tmp/bin:/usr/bin:/bin"

FUNCS="meta ready json has off deploy_json status latest cancel rollback logs url set_key doctor"
FIELDS='["name","id","auto","deployable","paused","repo","ref","domain","url","dashboardUrl","lastAt","lastState","lastSha","lastMsg","fetchError","phase"]'
PHASES='["queued","building","ready","failed","canceled"]'
# How each capability is tried when a provider says it does not have it.
cap_call() {  # cap_call <p> <cap>
  case "$2" in
    preview) echo "${1}_deploy_json $CONTRACT_ID --preview" ;;
    sha) echo "${1}_deploy_json $CONTRACT_ID --sha abc1234" ;;
    off) echo "${1}_off $CONTRACT_ID" ;;
    cancel) echo "${1}_cancel $CONTRACT_ID $CONTRACT_DEPLOY" ;;
    rollback) echo "${1}_rollback $CONTRACT_ID" ;;
    logs) echo "${1}_logs $CONTRACT_ID 5" ;;
  esac
}

# One provider's world: a fresh config (with the fixture's config files) and its env file.
cli() {  # cli <p> deploys-args... (stdout only)
  local p="$1"; shift
  # shellcheck source=/dev/null
  ( . "tests/fixtures/$p/env"; env -u DEPLOYS_LIB PATH="$STUBPATH" DEPLOYS_CONFIG="$tmp/config-$p" HOME="$tmp" NO_COLOR=1 /bin/bash ./deploys "$@" 2>"$tmp/err" </dev/null )
}
lib() {  # lib <p> <shell code>: the code with deploys sourced (DEPLOYS_LIB=1)
  local p="$1"; shift
  # shellcheck source=/dev/null
  ( . "tests/fixtures/$p/env"; PATH="$STUBPATH" DEPLOYS_CONFIG="$tmp/config-$p" HOME="$tmp" NO_COLOR=1 DEPLOYS_LIB=1 \
      /bin/bash -c '. ./deploys; set +e; '"$1" 2>"$tmp/err" </dev/null )
}

for f in providers/*.sh; do
  p="$(basename "$f" .sh)"
  # A provider with its own test file (tests/providers/<p>.sh) and no contract fixtures is covered there.
  [ -f "tests/fixtures/$p/env" ] || { [ -f "tests/providers/$p.sh" ] && continue; }
  [ -d "tests/fixtures/$p" ] || { fail "$p: fixtures" "tests/fixtures/$p is missing"; continue; }
  rm -rf "$tmp/config-$p"; mkdir -p "$tmp/config-$p"
  [ -d "tests/fixtures/$p/config" ] && cp -R "tests/fixtures/$p/config"/. "$tmp/config-$p/"
  CONTRACT_ID="" CONTRACT_NAME="" CONTRACT_DEPLOY=""
  # shellcheck source=/dev/null
  . "tests/fixtures/$p/env"

  missing="$(lib "$p" 'for v in '"$FUNCS"'; do declare -F "'"$p"'_$v" >/dev/null || echo "$v"; done' | tr '\n' ' ')"
  expect "$p: every contract function exists" "$missing" ""

  meta="$(lib "$p" "${p}_meta")"
  expect "$p: _meta is valid" "$(echo "$meta" | jq -c --arg p "$p" '
      [(.id == $p), (.label | type == "string" and length > 0), (.noun | type == "string"),
       (.keyEnv | type == "array" and all(type == "string")), (.keychain == null or (.keychain | type == "string")),
       ((.defaultOn // false) | type == "boolean"),
       (.caps | type == "object" and ([.off, .sha, .cancel, .rollback, .logs, .preview] | all(type == "boolean")))] | all' 2>&1)" "true"

  : > "$CALLS"
  out="$(cli "$p" "$p" json)"; rc=$?
  expect "$p: json from the fixtures" "$rc:$(echo "$out" | jq -r 'type' 2>&1)" "0:array"
  expect "$p: json has every field" "$(echo "$out" | jq -c --argjson f "$FIELDS" '[.[] | . as $e | $f[] | . as $k | select($e | has($k) | not)] | unique' 2>&1)" "[]"
  expect "$p: phase is in the enum" "$(echo "$out" | jq -c --argjson ph "$PHASES" '[.[] | select(.phase as $x | $ph | index($x) | not) | .name]' 2>&1)" "[]"
  expect "$p: each phase is the expected one" "$(echo "$out" | jq -cS 'map({(.name): .phase}) | add' 2>&1)" "$(jq -cS . "tests/fixtures/$p/expect.json")"
  expect "$p: building follows the phase" "$(echo "$out" | jq -c '[.[] | select(.building != (.phase == "queued" or .phase == "building")) | .name]')" "[]"
  expect "$p: names are remembered with platform and id" \
    "$(jq -c --arg p "$p" '[.[] | select(.platform == $p)] | length' "$tmp/config-$p/names.json" 2>&1)" "$(echo "$out" | jq length)"

  expect "$p: _has gives the id" "$(lib "$p" "${p}_has $CONTRACT_NAME")" "$CONTRACT_ID"
  for v in status latest; do
    if [ "$v" = status ]; then s="$(lib "$p" "${p}_status $CONTRACT_ID $CONTRACT_DEPLOY")"; else s="$(lib "$p" "${p}_latest $CONTRACT_ID")"; fi
    IFS=$'\t' read -r sid sph sraw <<<"$s"
    expect "$p: _$v is deployId<TAB>phase<TAB>state" "$([ -n "$sid" ] && [ -n "$sraw" ] && echo "$PHASES" | jq -e --arg x "$sph" 'index($x) != null' >/dev/null && echo ok || echo "[$s]")" "ok"
  done
  rm -rf "$tmp/config-$p/locks"
  d="$(lib "$p" "${p}_deploy_json $CONTRACT_ID")"
  expect "$p: _deploy_json prints id, url, state, phase" \
    "$(echo "$d" | jq -c --argjson ph "$PHASES" '[has("id"), has("url"), has("state"), (.phase as $x | $ph | index($x) != null)] | all' 2>&1)" "true"
  expect "$p: _url prints an address" "$(lib "$p" "${p}_url $CONTRACT_ID" | grep -c '^https://')" "1"
  expect "$p: _doctor prints a JSON object" "$(lib "$p" "${p}_doctor" | jq -r type 2>&1)" "object"

  label="$(echo "$meta" | jq -r .label)"
  for cap in $(echo "$meta" | jq -r '.caps | to_entries[] | select(.value == false) | .key'); do
    : > "$CALLS"; rm -rf "$tmp/config-$p/locks"
    lib "$p" "$(cap_call "$p" "$cap")" >/dev/null; rc=$?
    expect "$p: without $cap, \"$label cannot …\" and nothing sent" \
      "$rc:$(grep -c "$label cannot" "$tmp/err"):$(grep -cE ' (POST|PATCH|DELETE) ' "$CALLS")" "1:1:0"
  done
done

# --- switching providers on and off ---
# A copy of the two default providers plus "extra", a provider that is off by default and writes
# down every call, in a folder of its own (DEPLOYS_DIR): the real providers/ folder is not touched.
# Only vercel and render are copied, so these checks stay the same as more providers land.
dd="$tmp/dd"; mkdir -p "$dd/providers"; cp providers/vercel.sh providers/render.sh "$dd/providers/"
cat > "$dd/providers/extra.sh" <<'SH'
# shellcheck shell=bash
extra_meta() { printf '%s\n' '{"id":"extra","label":"Extra","noun":"site","defaultOn":false,"keyEnv":["EXTRA_TOKEN"],"keychain":"deploy-center-extra","caps":{"off":false,"sha":false,"cancel":false,"rollback":false,"logs":false,"preview":false}}'; }
extra_ready() { echo "extra ready" >> "$CALLS"; key_of extra >/dev/null; }
extra_json() { echo "extra json" >> "$CALLS"; echo '[{"name":"site1","id":"x-1","auto":false,"deployable":false,"paused":false,"repo":null,"ref":null,"domain":null,"url":null,"dashboardUrl":null,"lastAt":null,"lastState":"done","lastSha":null,"lastMsg":null,"fetchError":null,"phase":"ready"}]'; }
extra_has() { echo "extra has $1" >> "$CALLS"; [ "$1" = site1 ] && echo x-1; }
for v in off deploy_json status latest cancel rollback logs url set_key doctor; do eval "extra_$v() { echo \"extra $v\" >> \"\$CALLS\"; die \"Extra cannot $v\"; }"; done
SH
pc="$tmp/config-providers"; rm -rf "$pc"; mkdir -p "$pc"
cp tests/fixtures/vercel/config/* "$pc/"
both() {  # deploys with both real providers' stand-ins and the extra provider
  ( . tests/fixtures/vercel/env; . tests/fixtures/render/env; export EXTRA_TOKEN=tok
    env -u DEPLOYS_LIB PATH="$STUBPATH" DEPLOYS_DIR="$dd" DEPLOYS_CONFIG="$pc" HOME="$tmp" NO_COLOR=1 /bin/bash "$root/deploys" "$@" 2>"$tmp/err" </dev/null )
}

: > "$CALLS"
pj="$(both providers --json)"
expect "providers --json: Vercel and Render on, others off" "$(echo "$pj" | jq -c 'map({(.id): .enabled}) | add')" '{"extra":false,"render":true,"vercel":true}'
expect "providers --json: an off provider is not asked whether it is set up" "$(echo "$pj" | jq -c '[.[] | select(.id == "extra") | .ready]'):$(grep -c '^extra' "$CALLS")" '[null]:0'
expect "providers --json: meta fields are there" "$(echo "$pj" | jq -c '[.[] | has("label") and has("caps") and has("keyEnv")] | all')" "true"
expect "no providers.json until something is switched" "$([ -e "$pc/providers.json" ] && echo there || echo none)" "none"

: > "$CALLS"
l="$(both list --json)"; rc=$?
expect "list --json: every project of the providers that are on" "$rc:$(echo "$l" | jq -c 'map(.platform) | unique')" '0:["render","vercel"]'
expect "list --json: an off provider is never called" "$(grep -c '^extra' "$CALLS")" "0"
both changed --json >/dev/null; both status --no-github >/dev/null; both deploy-changed >/dev/null
expect "changed, status, deploy-changed: an off provider is never called" "$(grep -c '^extra' "$CALLS")" "0"
both explain site1 >/dev/null; rc=$?
expect "lookup: an off provider is not asked" "$rc:$(grep -c '^extra' "$CALLS")" "1:0"
both extra json >/dev/null; rc=$?
expect "an off provider refuses its commands" "$rc:$(grep -c 'Extra is off. Turn it on: deploys providers enable extra' "$tmp/err")" "1:1"

expect "providers enable" "$(both providers enable extra)" "Extra is on."
expect "providers.json keeps the choice" "$(jq -c . "$pc/providers.json")" '{"enabled":["extra","render","vercel"]}'
: > "$CALLS"
l="$(both list --json)"
expect "list --json: an enabled provider is read" "$(echo "$l" | jq -c '[.[] | select(.platform == "extra") | .name]'):$(grep -c '^extra json' "$CALLS")" '["site1"]:1'
expect "lookup through the names read: extra:site1 and site1" "$(both explain extra:site1 >/dev/null; echo $?):$(both explain site1 >/dev/null; echo $?)" "0:0"

expect "providers disable" "$(both providers disable render)" "Render is off: no command reads it any more."
expect "providers.json without it" "$(jq -c . "$pc/providers.json")" '{"enabled":["extra","vercel"]}'
: > "$CALLS"
both list --json >/dev/null; both changed --json >/dev/null; both status --no-github >/dev/null
expect "Render off: no Render call, no key asked for" "$(grep -c '^curl' "$CALLS")" "0"
both explain web >/dev/null
expect "Render off: a remembered Render name is not looked up there" "$(grep -c '^curl' "$CALLS")" "0"
expect "Render off: render:web is refused" "$(both explain render:web >/dev/null; grep -c 'Render is off' "$tmp/err")" "1"
expect "unknown provider is refused" "$(both providers enable nope >/dev/null; grep -c 'Known: extra render vercel' "$tmp/err")" "1"
both providers enable render >/dev/null; both providers disable extra >/dev/null
expect "back to the defaults" "$(both providers --json | jq -c 'map(select(.enabled) | .id)')" '["render","vercel"]'
rm -f "$pc/providers.json"; printf 'not json' > "$pc/providers.json"
expect "a broken providers.json means the defaults" "$(both providers --json | jq -c 'map(select(.enabled) | .id)')" '["render","vercel"]'

# --- names: p:name, the same name on two platforms ---
rm -f "$pc/providers.json"
jq -n '[{name:"same",platform:"vercel",id:"same"},{name:"same",platform:"render",id:"srv-a"}]' > "$pc/names.json"
both explain same >/dev/null; rc=$?
expect "a name on two platforms asks which" "$rc:$(grep -c 'Say which: render:same' "$tmp/err")" "1:1"
expect "the provider prefix picks one" "$(both explain render:web >/dev/null; echo $?)" "0"

# --- the script finds its providers through a symlink, and says so when they are missing ---
# Every providers/*.sh, in the order deploys reads them; only vercel and render are on by default.
ids_all() { for f in providers/*.sh; do basename "$f" .sh; done | jq -Rnc '[inputs]'; }
expect "a symlinked deploys: only vercel and render on by default" \
  "$(env -u DEPLOYS_DIR PATH="$STUBPATH" DEPLOYS_CONFIG="$pc" /bin/bash "$root/deploys" providers --json | jq -c 'map(select(.enabled) | .id)')" '["render","vercel"]'
mkdir -p "$tmp/link"; ln -s "$root/deploys" "$tmp/link/deploys"
expect "a symlinked deploys finds providers/" "$(env -u DEPLOYS_DIR PATH="$STUBPATH" DEPLOYS_CONFIG="$pc" /bin/bash "$tmp/link/deploys" providers --json | jq -c 'map(.id)')" "$(ids_all)"
mkdir -p "$tmp/alone"; cp deploys "$tmp/alone/"
expect "without providers/: a clear error" "$(env -u DEPLOYS_DIR PATH="$STUBPATH" DEPLOYS_CONFIG="$pc" NO_COLOR=1 /bin/bash "$tmp/alone/deploys" doctor 2>&1 | grep -c 'No providers in')" "1"

echo
[ "$fails" = 0 ] && echo "All provider contract tests passed." || { echo "$fails failed."; exit 1; }
