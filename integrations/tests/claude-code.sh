#!/bin/bash
# Checks the Claude Code plugin (integrations/claude-code) and its marketplace file
# (.claude-plugin/marketplace.json) against the documented format:
#   https://code.claude.com/docs/en/plugins/marketplace-reference
#   https://code.claude.com/docs/en/plugins/manifest-reference
#   https://code.claude.com/docs/en/plugins/components
#   https://code.claude.com/docs/en/skills
#   https://code.claude.com/docs/en/hooks
# Needs bash and jq only. When the `claude` CLI is installed, `claude plugin validate --strict`
# runs as well (the authoritative check). Prints ok/FAIL lines; exits 1 on any failure.
# Run on its own (integrations/tests/claude-code.sh) or from integrations/tests/run.sh.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "check failed"; fi; }

mkt=.claude-plugin/marketplace.json
plug=integrations/claude-code
man="$plug/.claude-plugin/plugin.json"
hooks="$plug/hooks/hooks.json"
idre='^[A-Za-z0-9][A-Za-z0-9._-]*$'
kebab='^[a-z0-9]+(-[a-z0-9]+)*$'

for f in "$mkt" "$man" "$hooks" "$plug/mcp/deploys.mcp.json"; do
  check "json: $f parses" jq -e . "$f"
done

# --- marketplace.json: at the repo root, so `marketplace add owner/repo` finds it ---
check "marketplace: name, owner.name and plugins are set" \
  jq -e '(.name|type=="string" and length>0) and (.owner.name|type=="string" and length>0) and (.plugins|type=="array" and length>0)' "$mkt"
check "marketplace: name is a valid id" jq -e --arg re "$idre" '.name | test($re) and (contains("..")|not)' "$mkt"
check "marketplace: name is not reserved" jq -e '.name as $n | ["claude-code-marketplace","claude-code-plugins","claude-plugins-official",
  "anthropic-marketplace","anthropic-plugins","agent-skills","anthropic-agent-skills","inline","builtin","skills-dir","synced",
  "npm","pip","uv","cargo","github","gh"] | index($n) | not' "$mkt"
check "marketplace: name has no claude/anthropic/official" jq -e '.name | test("claude|anthropic|official";"i") | not' "$mkt"
check "marketplace: description is set" jq -e '.description|type=="string" and length>0' "$mkt"
check "marketplace: only documented top-level keys" jq -e 'keys - ["$schema","name","owner","plugins","description","version","metadata",
  "forceRemoveDeletedPlugins","allowCrossMarketplaceDependenciesOn","renames"] | length == 0' "$mkt"
check "marketplace: every entry has a valid name and a source" \
  jq -e --arg re "$idre" '.plugins | all((.name|type=="string" and test($re)) and (.source != null))' "$mkt"
check "marketplace: entry names are unique" jq -e '.plugins | map(.name) | length == (unique|length)' "$mkt"
src="$(jq -r '.plugins[] | select(.name=="deploy-center") | .source' "$mkt")"
case "$src" in
  ./*) case "$src" in *..*) fail "marketplace: source has no .." "$src" ;; *) ok "marketplace: source is ./ relative, no .." ;; esac ;;
  *) fail "marketplace: source starts with ./" "$src" ;;
esac
expect_dir="./$plug"
[ "$src" = "$expect_dir" ] && ok "marketplace: source is $expect_dir" || fail "marketplace: source is $expect_dir" "$src"
[ -f "${src#./}/.claude-plugin/plugin.json" ] && ok "marketplace: source holds a plugin" || fail "marketplace: source holds a plugin" "$src"
[ "$(jq -r '.plugins[0].name' "$mkt")" = "$(jq -r .name "$man")" ] \
  && ok "marketplace: entry name equals the plugin.json name" || fail "marketplace: entry name equals the plugin.json name" "differ"
[ "$(jq -r .name "$mkt")" = deploy-center ] && [ "$(jq -r .name "$man")" = deploy-center ] \
  && ok "install id is deploy-center@deploy-center" || fail "install id is deploy-center@deploy-center" "names changed"

# --- plugin.json ---
check "plugin: name is kebab-case" jq -e --arg re "$kebab" '.name | test($re)' "$man"
check "plugin: name is not reserved" jq -e '.name | (test("^(claude|anthropic|anthropics|cc-plugin)-";"i") or test("\\b(claude|anthropic)\\b";"i")) | not' "$man"
check "plugin: version, description and author.name" \
  jq -e '(.version|type=="string") and (.description|type=="string" and length>0) and (.author.name|type=="string" and length>0)' "$man"
check "plugin: homepage is a URL" jq -e '.homepage | test("^https://")' "$man"
check "plugin: only documented top-level keys" jq -e 'keys - ["$schema","name","displayName","version","description","author","homepage",
  "repository","license","keywords","metadata","icon","documentationUrl","supportUrl","privacyPolicyUrl","termsOfServiceUrl",
  "defaultEnabled","dependencies","settings","userConfig","channels","skills","commands","agents","hooks","mcpServers",
  "lspServers","outputStyles","workflows","experimental"] | length == 0' "$man"
check "plugin: component paths start with ./ and have no .." jq -e '[.skills,.commands,.agents,.hooks,.mcpServers,.outputStyles]
  | map(select(type=="string")) | all(startswith("./") and (contains("..")|not))' "$man"
check "plugin: userConfig options are strict and typed" jq -e '(.userConfig // {}) | to_entries | all(
  (.key|test("^[A-Za-z_][A-Za-z0-9_]*$"))
  and (.value|keys - ["type","title","description","required","default","options","multiple","sensitive","min","max"] | length==0)
  and (.value.type|IN("string","number","boolean","directory","file"))
  and (.value.title|type=="string") and (.value.description|type=="string"))' "$man"
[ ! -e "$plug/CLAUDE.md" ] && ok "plugin: no CLAUDE.md at the root (not loaded)" || fail "plugin: no CLAUDE.md at the root" "found"
[ ! -e "$plug/.mcp.json" ] && ok "plugin: no .mcp.json until integrations/mcp is installable" || fail "plugin: no default .mcp.json" "found"

# --- hooks/hooks.json ---
check "hooks: wrapped in a top-level hooks key" jq -e '.hooks|type=="object"' "$hooks"
check "hooks: known events only" jq -e '.hooks | keys - ["PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest",
  "PermissionDenied","UserPromptSubmit","Notification","Stop","SubagentStop","SessionStart","SessionEnd","PreCompact"] | length == 0' "$hooks"
check "hooks: each group has a hooks array of command handlers" jq -e '[.hooks[][]] | all(
  (.hooks|type=="array" and length>0) and (.hooks|all(.type=="command" and (.command|type=="string"))))' "$hooks"
check "hooks: timeouts are numbers" jq -e '[.hooks[][].hooks[] | .timeout // 1] | all(type=="number" and . > 0)' "$hooks"
check "hooks: PostToolUse on Bash, only for git push" jq -e '.hooks.PostToolUse[0] | .matcher=="Bash" and .hooks[0].if=="Bash(git push *)"' "$hooks"
check "hooks: \${CLAUDE_PLUGIN_ROOT} is quoted in shell form" \
  jq -e '[.hooks[][].hooks[] | select(.args == null) | .command] | all(test("\"\\$\\{CLAUDE_PLUGIN_ROOT\\}[^\"]*\""))' "$hooks"
while IFS= read -r p; do
  f="$plug/${p#/}"
  [ -x "$f" ] && ok "hooks: $p exists and is executable" || fail "hooks: $p exists and is executable" "$f"
done < <(jq -r '.hooks[][].hooks[].command | capture("\\$\\{CLAUDE_PLUGIN_ROOT\\}(?<p>[^\" ]+)").p' "$hooks")

# --- skills: skills/<name>/SKILL.md with YAML frontmatter ---
known_fm=" name description when_to_use argument-hint disable-model-invocation user-invocable allowed-tools arguments disallowed-tools model effort context agent background hooks paths shell metadata license compatibility "
for want in deploy-center deploys-waiting deploys-status deploys-fix deploys-ship; do
  f="$plug/skills/$want/SKILL.md"
  [ -f "$f" ] || { fail "skill $want: SKILL.md exists" "$f"; continue; }
  [ "$(head -1 "$f")" = "---" ] && fm="$(awk 'NR==1{next} /^---$/{exit} {print}' "$f")" || fm=""
  [ -n "$fm" ] && ok "skill $want: has frontmatter" || { fail "skill $want: has frontmatter" "none"; continue; }
  grep -qE '^description: .{20,}' <<<"$fm" && ok "skill $want: has a description" || fail "skill $want: has a description" "missing"
  bad=""; while IFS= read -r k; do case "$known_fm" in *" $k "*) ;; *) bad="$bad $k" ;; esac; done < <(sed -nE 's/^([A-Za-z_-]+):.*/\1/p' <<<"$fm")
  [ -z "$bad" ] && ok "skill $want: documented frontmatter fields only" || fail "skill $want: documented frontmatter fields only" "$bad"
  n="$(sed -nE 's/^name: *//p' <<<"$fm")"
  [ -z "$n" ] || [ "$n" = "$want" ] && ok "skill $want: name matches its folder" || fail "skill $want: name matches its folder" "$n"
done
# The safety model, in the files themselves.
for s in deploys-waiting deploys-status deploys-fix deploys-ship; do
  grep -q '^disable-model-invocation: true' "$plug/skills/$s/SKILL.md" \
    && ok "skill $s: only the user runs it" || fail "skill $s: only the user runs it" "model-invocable"
done
if grep -hE '^allowed-tools:' "$plug"/skills/*/SKILL.md | grep -qiE 'deploy-changed|deploy-json|vercel deploy|render deploy|rollback|autodeploy'; then
  fail "skills: no deploy command is pre-approved" "found in allowed-tools"
else ok "skills: no deploy command is pre-approved"; fi
grep -q 'Stop and wait for the answer' "$plug/skills/deploys-ship/SKILL.md" \
  && ok "deploys-ship: asks before deploying" || fail "deploys-ship: asks before deploying" "missing"
grep -qi 'never deploy without an explicit OK' "$plug/skills/deploy-center/SKILL.md" \
  && ok "deploy-center skill: never deploy without an explicit OK" || fail "deploy-center skill: never deploy without an explicit OK" "missing"

# --- optional MCP config (not loaded by the plugin) ---
check "mcp example: mcpServers.deploys runs integrations/mcp/server.mjs, deploys off" jq -e '.mcpServers.deploys
  | .command=="node" and (.args[0]|endswith("integrations/mcp/server.mjs")) and .env.DEPLOYS_MCP_ALLOW_DEPLOY=="0"' "$plug/mcp/deploys.mcp.json"

# --- the official validator, when installed ---
if command -v claude >/dev/null 2>&1; then
  for target in "$plug" .; do
    if out="$(timeout 120 claude plugin validate --strict "$target" 2>&1)"; then ok "claude plugin validate --strict $target"
    else fail "claude plugin validate --strict $target" "$(tail -5 <<<"$out")"; fi
  done
else
  echo "skip claude plugin validate (claude CLI not installed)"
fi

[ "${1:-}" = --quiet ] || { echo; [ "$fails" = 0 ] && echo "All passed." || echo "$fails failed."; }
[ "$fails" = 0 ]
