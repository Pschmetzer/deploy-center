// Unit tests for src/lib/insights.ts: the costs, journal, guard and freeze answers of the CLI, read from
// fixtures (no network, no Raycast, no real account).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import {
  agoText,
  freezeText,
  guardSummary,
  leftText,
  monthSentence,
  monthTitle,
  parseCosts,
  parseCsv,
  parseFreeze,
  parseGuard,
  parseJournal,
  perBuild,
  plain,
  ruleText,
  searchJournal,
  sinceDate,
} from "../src/lib/insights";

// The compiled tests live in .test-out/test/; the fixtures stay in test/fixtures/.
const fixture = (f: string) => readFileSync(join(__dirname, "../../test/fixtures", f), "utf8");
const NOW = new Date("2026-11-20T10:00:00Z");

test("parseCosts: the sum of this month, the days and the projects", () => {
  const c = parseCosts(fixture("costs.json"), NOW)!;
  assert.deepEqual(c.month, { month: "2026-11", total: 12.345, build: 8.1, days: 14 });
  assert.equal(c.days.length, 3);
  assert.equal(c.projects[0].name, "app-web");
  assert.equal(monthTitle(c), "$12.35");
  assert.equal(monthSentence(c), "$12.35 in 2026-11 (builds $8.10)");
});

test("parseCosts: a missing day makes the sum a floor; another month has no sum; junk is null", () => {
  const raw = JSON.parse(fixture("costs.json"));
  const floor = parseCosts(JSON.stringify({ ...raw, missingDays: 2 }), NOW)!;
  assert.equal(monthTitle(floor), "$12.35+");
  assert.match(monthSentence(floor), /a floor/);
  const dec = parseCosts(fixture("costs.json"), new Date("2026-12-02T00:00:00Z"))!;
  assert.equal(dec.month, null);
  assert.equal(monthTitle(dec), undefined);
  assert.equal(monthSentence(dec), "No charges read for this month yet.");
  for (const bad of ["", "nope", "[]", "{}", '{"months":[]}']) assert.equal(parseCosts(bad, NOW), null, bad);
});

test("perBuild: the price of one build, only where the count is known", () => {
  const c = parseCosts(fixture("costs.json"), NOW)!;
  assert.equal(perBuild(c.projects[0]), 0.5);
  assert.equal(perBuild(c.projects[1]), null);
  assert.equal(perBuild(c.projects[2]), null);
});

test("parseCsv: quotes, doubled quotes, line breaks inside a field, CRLF", () => {
  assert.deepEqual(parseCsv('a,"b,c","d ""q"""\r\n"x\ny",,z\n'), [
    ["a", "b,c", 'd "q"'],
    ["x\ny", "", "z"],
  ]);
  assert.deepEqual(parseCsv(""), []);
});

test("parseJournal: newest first, the formula guard quote is taken off, multi-line details stay together", () => {
  const rows = parseJournal(fixture("journal.csv"));
  assert.equal(rows.length, 5);
  assert.deepEqual(
    rows.map((r) => r.name),
    ["site", "api", "app-web", "app-web", "blog"],
  );
  assert.equal(rows[2].result, "failed");
  assert.equal(rows[2].detail, "Build failed\nsecond line of the error");
  assert.equal(rows[4].detail, '-- forced: release "hotfix"');
  assert.equal(rows[0].detail, "");
  assert.deepEqual(parseJournal("not,the,header\n1,2,3"), []);
});

test("searchJournal: every word must match, any case; empty keeps all; a limit", () => {
  const rows = parseJournal(fixture("journal.csv"));
  assert.equal(searchJournal(rows, "").length, 5);
  assert.deepEqual(
    searchJournal(rows, "APP-web failed").map((r) => r.result),
    ["failed"],
  );
  assert.deepEqual(
    searchJournal(rows, "render rolled").map((r) => r.name),
    ["api"],
  );
  assert.deepEqual(
    searchJournal(rows, "hotfix").map((r) => r.name),
    ["blog"],
  );
  assert.deepEqual(searchJournal(rows, "app-web nothing"), []);
  assert.equal(searchJournal(rows, "", 2).length, 2);
});

test("sinceDate: the day `days` back, UTC", () => {
  assert.equal(sinceDate(NOW, 90), "2026-08-22");
  assert.equal(sinceDate(NOW, 0), "2026-11-20");
});

test("parseGuard and its texts", () => {
  const g = parseGuard(fixture("guard.json"))!;
  assert.equal(g.enabled, true);
  assert.equal(g.actions.length, 2);
  assert.equal(g.actions[1].error, "HTTP 401");
  assert.deepEqual(g.pathMissing, ["jq"]);
  const now = 1763630000 + 7200;
  assert.equal(guardSummary(g, now), "on, every 30 minutes; last run 2 h ago");
  assert.equal(guardSummary({ ...g, lastDry: true }, now), "on, every 30 minutes; last run 2 h ago (dry run)");
  assert.equal(guardSummary({ ...g, lastRun: null }, now), "on, every 30 minutes; has not run yet");
  assert.match(guardSummary({ ...g, enabled: false }, now), /^off/);
  assert.equal(leftText(g.allowances[0].expiresAt, 1763630000), "2 h left");
  assert.equal(leftText(g.allowances[0].expiresAt, 1763640000 - 90), "1 min left");
  assert.equal(leftText(g.allowances[0].expiresAt, 1763640001), "expired");
  assert.equal(agoText(100, 130), "1 min ago");
  assert.equal(agoText(0, 3 * 86400), "3 d ago");
  for (const bad of ["", "x", "[]", "{}", '{"enabled":"yes"}']) assert.equal(parseGuard(bad), null, bad);
});

test("parseFreeze and its texts", () => {
  const f = parseFreeze(fixture("freeze.json"))!;
  assert.equal(f.closedNow, true);
  assert.equal(freezeText(f), "Closed now (release freeze)");
  assert.equal(freezeText({ ...f, closedNow: false }), "Open now");
  assert.equal(freezeText({ ...f, configured: false, rules: [] }), "No closed times");
  assert.equal(freezeText(null), "Not read");
  assert.equal(ruleText(f.rules[0]), "fri 15:00–24:00 (release freeze)");
  assert.equal(ruleText(f.rules[1]), "every day 00:00–06:00");
  for (const bad of ["", "x", "[]", '{"rules":[]}']) assert.equal(parseFreeze(bad), null, bad);
});

test("plain: control characters out, long text cut", () => {
  assert.equal(plain("a\u001b[0m\nb\t c"), "a [0m b c");
  assert.equal(plain("x".repeat(30), 10), "xxxxxxxxx…");
});
