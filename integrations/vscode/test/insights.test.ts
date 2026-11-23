import assert from "node:assert/strict";
import { test } from "node:test";
import { costStatusText, costTooltip, freezeStatusText, freezeTooltip, parseFreeze, outageStatusText, outageTooltip, parseHistory, parseOutages, parseMonthCost, pendingDetails, pendingLabel, pendingRows, pendingSummary, plain, rollbackPreview, rollbackPreviewText, ruleText } from "../src/insights";
import { mergeProjects } from "../src/model";

const NOW = new Date("2026-11-20T10:00:00Z");
const costs = (month: string, missing = 0) => JSON.stringify({ currency: "USD", missingDays: missing, days: [], months: [{ month: "2026-10", total: 99, build: 90, days: 31 }, { month, total: 12.345, build: 8.1, days: 14 }] });

test("parseMonthCost: the month of today, not another one", () => {
  const c = parseMonthCost(costs("2026-11"), NOW);
  assert.deepEqual(c, { month: "2026-11", usd: 12.345, buildUsd: 8.1, days: 14, partial: false, currency: "USD" });
  assert.equal(costStatusText(c!), "$(credit-card) $12.35");
  assert.equal(parseMonthCost(costs("2026-12"), NOW), null);
});

test("parseMonthCost: unread days make a floor; junk is null", () => {
  const c = parseMonthCost(costs("2026-11", 2), NOW)!;
  assert.equal(c.partial, true);
  assert.equal(costStatusText(c), "$(credit-card) $12.35+");
  assert.match(costTooltip(c), /floor/);
  for (const bad of ["", "nope", "[]", "{}", '{"months":[{"month":"2026-11","total":"x"}]}']) assert.equal(parseMonthCost(bad, NOW), null, bad);
});

const FREEZE = { configured: true, closedNow: true, reason: "release freeze", rules: [{ n: 1, days: ["fri"], from: "15:00", to: "24:00", reason: "release freeze" }, { n: 2, days: null, from: "00:00", to: "06:00", reason: null }] };

test("parseFreeze, its status text and tooltip", () => {
  const f = parseFreeze(JSON.stringify(FREEZE))!;
  assert.equal(f.closedNow, true);
  assert.equal(freezeStatusText(f), "$(lock) Deploys closed");
  assert.equal(freezeStatusText({ ...f, closedNow: false }), "$(unlock) Deploy window open");
  assert.equal(ruleText(f.rules[0]), "fri 15:00–24:00 (release freeze)");
  assert.equal(ruleText(f.rules[1]), "every day 00:00–06:00");
  assert.match(freezeTooltip(f), /Closed now: release freeze\..*\n1\. fri 15:00–24:00.*\n2\. every day/);
});

test("no closed times: nothing to show; junk is null", () => {
  assert.equal(freezeStatusText(parseFreeze('{"configured":false,"closedNow":false,"rules":[]}')), null);
  assert.equal(freezeStatusText(null), null);
  for (const bad of ["", "x", "[]", '{"rules":[]}']) assert.equal(parseFreeze(bad), null, bad);
});

const status = [{ platform: "vercel", name: "a", repo: "me/a", phase: "ready" }, { platform: "vercel", name: "b", repo: "me/b" }, { platform: "render", name: "c", repo: "me/c" }, { platform: "vercel", name: "d" }];
const changed = [
  { name: "a", platform: "vercel", pendingCommits: 2, pendingPRs: 1, oldestPendingAt: 1000, headSha: "abcdef123", headMsg: "Fix\u001b[31m login\nsecond" },
  { name: "b", platform: "vercel", pendingCommits: 5, pendingPRs: 0, oldestPendingAt: 2000 },
  { name: "c", platform: "render", pendingCommits: null },
];

test("pendingRows: most commits first, unknown last; details are plain text", () => {
  const rows = pendingRows(mergeProjects(changed, status), 1000 + 3 * 86400);
  assert.deepEqual(rows.map((r) => r.project.name), ["b", "a", "c"]);
  assert.equal(pendingLabel(rows[0]), "5 commits");
  assert.equal(pendingLabel(rows[2]), "commits waiting (count unknown)");
  assert.deepEqual(pendingDetails(rows[1]), ["abcdef1 Fix [31m login", "1 pull request waiting", "waiting for 3 d", "vercel · me/a"]);
  assert.equal(pendingSummary(rows), "7+ commits in 3 projects");
  assert.equal(pendingSummary(rows.slice(0, 1)), "5 commits in 1 project");
  assert.equal(pendingSummary([]), "");
});

test("plain: control characters out, long text cut", () => {
  assert.equal(plain("a\u0000b\nc\t d"), "a b c d");
  assert.equal(plain("x".repeat(200), 10), "xxxxxxxxx…");
});

const HIST = JSON.stringify([
  { when: "2026-11-19 09:00", target: "preview", state: "READY", commit: "fff9999", source: "git" },
  { when: "2026-11-18 14:05", target: "production", state: "READY", commit: "cccc333", source: "cli" },
  { when: "2026-11-18 14:00", target: "production", state: "READY", commit: "cccc333", source: "cli" },
  { when: "2026-11-17 10:00", target: "production", state: "ERROR", commit: "bbbb222", source: "git" },
  { when: "2026-11-16 08:30", target: "production", state: "READY", commit: "aaaa111", source: "git" },
]);

test("rollbackPreview: skips previews, failures and a redeploy of the same commit", () => {
  const p = rollbackPreview(parseHistory(HIST)!)!;
  assert.equal(p.current.commit, "cccc333");
  assert.equal(p.target.commit, "aaaa111");
  const t = rollbackPreviewText("web", p);
  assert.equal(t.message, "Rolling back web would put aaaa111 live again.");
  assert.match(t.detail, /Live now: cccc333 · 2026-11-18 14:05 UTC · cli\nWould go back to: aaaa111/);
  assert.match(t.detail, /Nothing was changed\.$/);
});

test("rollbackPreview: Render rows (no target, trigger instead of source); nothing to go back to", () => {
  const render = parseHistory(JSON.stringify([{ when: "w1", state: "live", commit: "d1", trigger: "api" }, { when: "w0", state: "deactivated", commit: "d0", trigger: "api" }]))!;
  const p = rollbackPreview(render)!;
  assert.equal(p.target.commit, "d0");
  assert.equal(p.target.source, "api");
  assert.equal(rollbackPreview(render.slice(0, 1)), null);
  assert.equal(rollbackPreview([]), null);
  assert.match(rollbackPreviewText("web", null).message, /no earlier production deploy/);
  assert.equal(parseHistory("nope"), null);
  assert.equal(parseHistory("{}"), null);
});

test("parseOutages: only the open ones, a text that is not the answer is refused", () => {
  const out = JSON.stringify({ projects: [{ name: "api", open: 1, openSince: "2026-11-19T08:00:00Z" }, { name: "web", open: 0, openSince: null }] });
  const list = parseOutages(out);
  assert.deepEqual(list, [{ name: "api", since: "2026-11-19T08:00:00Z" }]);
  assert.equal(outageStatusText(list), "$(error) 1 open outage");
  assert.equal(outageStatusText([]), null);
  assert.match(outageTooltip(list ?? []), /api · 2026-11-19 08:00/);
  assert.equal(parseOutages("nope"), null);
});
