#!/bin/bash
# deploys handover (lib/x-handover.sh) and deploys flaky (lib/x-flaky.sh): made-up journal, fixed clock.
. "$(dirname "$0")/lib.sh"
DEPLOYS_LIB=1 . ./deploys 2>/dev/null; set +e
now=1790000000; h=3600
at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
ln() { printf '{"at":"%s","platform":"%s","name":"%s","result":"%s","detail":"%s"}\n' "$(at "$1")" "$2" "$3" "$4" "$5"; }
j="$(
  ln $((now - 20*h)) vercel web live "Started"
  ln $((now - 6*h)) vercel web failed "build error"
  ln $((now - 5*h)) render api failed "oops"
  ln $((now - 4*h)) render api live "ok"
  ln $((now - 3*h)) cli web note "waiting for the schema fix"
  ln $((now - 90*h)) vercel old failed "far back"
)"
w='{"denied":true,"reason":"Friday"}'
o="$(handover_from "$now" 24 "$w" <<<"$j")"
expect "handover: only web fails now (api recovered, old is long past but still open)" "$(jq -c '[.open[].project]' <<<"$o")" '["vercel/web","vercel/old"]'
expect "handover: counts of the period" "$(jq -c '[.deploys,.failures]' <<<"$o")" "[2,2]"
expect "handover: the note" "$(jq -r '.notes[0].text' <<<"$o")" "waiting for the schema fix"
expect "handover: window closed" "$(jq -c '.window' <<<"$o")" '{"closed":true,"reason":"Friday"}'
txt="$(handover_print <<<"$o")"
has "handover text: failing" "$txt" "vercel/web  since"
has "handover text: window" "$txt" "Deploy window: CLOSED now (Friday)"
expect "handover: empty journal" "$(handover_from "$now" 24 '{}' </dev/null | handover_print | sed -n 2p)" "  Failing now: nothing"
cli handover --hours 0 >/dev/null 2>&1; expect "cli: --hours 0 refused" "$?" "1"
has "cli: runs on an empty journal" "$(cli handover)" "Deploy window: open"
expect "cli: json" "$(cli handover --json | jq -c '.open')" "[]"
# flaky
f="$(
  ln 1000 vercel web failed x; ln 1600 vercel web live Started
  ln 5000 vercel web failed x; ln 5300 vercel web live Started
  ln 9000 vercel web failed x; ln 20000 vercel web live Started
  ln 2000 render api failed x; ln 2100 render api live Started
)"
r="$(flaky_from 100000 1 1800 2 <<<"$f")"
expect "flaky: days window too short sees nothing" "$(jq -c '.rows' <<<"$r")" "[]"
r="$(flaky_from 100000 2 1800 2 <<<"$f")"
expect "flaky: web has two quick retries, api only one" "$(jq -c '.rows' <<<"$r")" '[{"project":"vercel/web","failures":3,"retries":2}]'
r="$(flaky_from 100000 2 1800 1 <<<"$f")"
expect "flaky: --min 1 lists both, most first" "$(jq -c '[.rows[].project]' <<<"$r")" '["vercel/web","render/api"]'
has "flaky text" "$(flaky_print <<<"$r")" "vercel/web  2 quick retries of 3 failures"
cli flaky --within 5x >/dev/null 2>&1; expect "cli: bad --within refused" "$?" "1"
has "cli: flaky on an empty journal" "$(cli flaky)" "none"
has "more lists handover and flaky" "$(cli more)" "handover"
exit "$fails"
