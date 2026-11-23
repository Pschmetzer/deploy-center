# shellcheck shell=bash
# Sourced by tests/cli-tests.sh (itself sourced at the end of tests/script-tests.sh): deploy json gitlab.
# e2e, O, E, tmp, run, fresh, expect come from script-tests.sh.

# 267: an unknown flag of deploy-json is refused, nothing starts.
fresh
expect "vercel deploy-json --sah: refused" "$(run "$O" "$E" vercel deploy-json web --sah abc; started)" $'1\n0'
expect "render deploy-json --sah: refused" "$(run "$O" "$E" render deploy-json api --sah abc; started)" $'1\n0'
# 266: vercel deploy --wait gives up like watch (exit 3) instead of asking for ever.
fresh
expect "vercel deploy --wait: gives up after five misses" "$(run "$O" "$E" vercel deploy web --wait; grep -c 'try 5 of 5' "$E")" $'3\n1'

# 263: a Vercel deploy from GitLab or Bitbucket has its commit as lastSha too.
expect "vercel json: gitlabCommitSha is the live commit" \
  "$( (vercel_projects() { echo '[{"name":"gl","link":null,"targets":{"production":{"createdAt":1000,"readyState":"READY","meta":{"gitlabCommitSha":"abc1","gitlabCommitMessage":"fix"}}}}]'; }
       vercel_call() { echo '{"deployments":[{"name":"gl","state":"READY","created":1,"uid":"d1","meta":{"bitbucketCommitSha":"abc1"}}]}'; }
       repos_json() { echo '{}'; }; vercel_json | jq -c '.[0] | [.lastSha, .lastMsg, .latestSha]') )" '["abc1","fix","abc1"]'

# 264: a link deploys cannot write down (Bitbucket) is not removed.
echo '{}' > "$tmp/repos264.json"; : > "$CALLS"
out="$( (REPOS="$tmp/repos264.json"; vercel_call() { echo '{"link":{"type":"bitbucket","productionBranch":"main"}}'; }
         vercel() { echo "vercel $*" >> "$CALLS"; }; vercel_off_one bb) 2>&1)"; rc=$?
expect "vercel off: a Bitbucket link stays when its repo is not known" "$rc:$(grep -c DELETE "$CALLS"):$(echo "$out" | grep -c 'stays connected')" "1:0:1"
# 265: a GitLab mapping says where to connect it again, not "repo is not known".
echo '{"gl":{"type":"gitlab","repo":"gitlab.com/g/app","projectId":7,"ref":"main"}}' > "$tmp/repos265.json"
expect "vercel on: a GitLab mapping points to the dashboard" \
  "$( (REPOS="$tmp/repos265.json"; vercel_on_one gl) 2>&1 | grep -c 'Vercel dashboard')" "1"

