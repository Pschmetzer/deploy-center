import assert from "node:assert/strict";
import { test } from "node:test";
import { describe, mergeProjects, parseArray, platformLabel, statusText, summarize } from "../src/model";

test("parseArray keeps an array, refuses anything else", () => {
  assert.deepEqual(parseArray('[{"a":1}]'), [{ a: 1 }]);
  assert.equal(parseArray(""), null);
  assert.equal(parseArray("Error: no"), null);
  assert.equal(parseArray('{"a":1}'), null);
  assert.deepEqual(parseArray("[1, null, {\"b\":2}]\n"), [{ b: 2 }]);
});

test("mergeProjects: waiting only from changed, state from status", () => {
  const p = mergeProjects(
    [{ name: "a", platform: "vercel", repo: "me/a", pendingCommits: 3, pendingPRs: 1 }],
    [
      { name: "a", platform: "vercel", repo: "me/a", building: false, state: "READY", changed: true },
      { name: "b", platform: "render", building: false, state: "build_failed", changed: true },
      { name: "c", platform: "vercel", building: true, state: "BUILDING" },
      { name: "", platform: "vercel" }, { name: "x", platform: "No Provider" },
    ]);
  assert.deepEqual(p.map((x) => x.name), ["b", "c", "a"]);
  const [b, c, a] = p;
  assert.equal(b.failed, true); assert.equal(b.waiting, false, "status' changed is not trusted (ignored projects)");
  assert.equal(c.building, true); assert.equal(c.failed, false);
  assert.equal(a.waiting, true); assert.equal(a.pendingCommits, 3); assert.equal(a.repo, "me/a");
});

test("mergeProjects: a building project is not failed, and changed alone works", () => {
  const p = mergeProjects([{ name: "a", platform: "render", latestState: "build_failed" }], null);
  assert.equal(p[0].failed, true);
  assert.equal(mergeProjects(null, [{ name: "a", platform: "vercel", building: true, state: "ERROR" }])[0].failed, false);
  assert.deepEqual(mergeProjects(null, null), []);
});

test("summary and status bar text", () => {
  const p = mergeProjects(
    [{ name: "a", platform: "vercel", pendingCommits: 3 }, { name: "b", platform: "vercel", pendingCommits: null }, { name: "c", platform: "vercel", pendingCommits: 1 }],
    null);
  const s = summarize(p);
  assert.deepEqual(s, { waiting: 3, commits: 4, commitsPartial: true, building: 0, failed: 0 });
  assert.equal(statusText(s), "⏳ 3 waiting");
  assert.equal(statusText({ waiting: 0, commits: 0, commitsPartial: false, building: 0, failed: 0 }), "$(check) up to date");
  assert.equal(statusText({ waiting: 1, commits: 1, commitsPartial: false, building: 2, failed: 1 }), "$(error) 1 failed  $(sync~spin) 2 building  ⏳ 1 waiting");
});

test("describe", () => {
  const [a] = mergeProjects([{ name: "a", platform: "vercel", pendingCommits: 1, pendingPRs: 2, oldestPendingAt: 1000 }], null);
  assert.equal(describe(a, 1000 + 3 * 86400), "1 commit, 2 PRs waiting (3 d) · vercel");
  const [b] = mergeProjects(null, [{ name: "b", platform: "render", state: "build_failed" }]);
  assert.equal(describe(b), "failed (build_failed) · render");
  const [c] = mergeProjects(null, [{ name: "c", platform: "render", state: "live" }]);
  assert.equal(describe(c), "up to date · render");
});

test("phase decides building and failed when the CLI has it", () => {
  const p = mergeProjects(
    [{ name: "w", platform: "netlify", phase: "failed", latestState: "error" }],
    [
      { name: "a", platform: "vercel", phase: "failed", state: "ERROR" },
      { name: "b", platform: "render", phase: "queued", building: true, state: "created" },
      // The platform's word says failed, the phase says canceled: canceled is not a failure.
      { name: "c", platform: "vercel", phase: "canceled", state: "CANCELED_ERROR" },
      { name: "d", platform: "amplify", phase: "ready", state: "SUCCEED" },
    ]);
  const by = Object.fromEntries(p.map((x) => [x.name, x]));
  assert.equal(by.a.failed, true);
  assert.equal(by.b.building, true); assert.equal(by.b.failed, false);
  assert.equal(by.c.failed, false);
  assert.equal(by.d.failed, false); assert.equal(by.d.platform, "amplify");
  assert.equal(by.w.failed, true); assert.equal(by.w.waiting, true);
});

test("every provider is a project, not only Vercel and Render", () => {
  const p = mergeProjects(null, [
    { name: "a", platform: "cloudflare" }, { name: "b", platform: "hook" }, { name: "c", platform: "Not A Provider!" }, { name: "d", platform: 3 },
  ]);
  assert.deepEqual(p.map((x) => x.platform), ["cloudflare", "hook"]);
  assert.equal(platformLabel("amplify"), "AWS Amplify");
  assert.equal(platformLabel("fly"), "Fly");
});

test("a name on two platforms is passed as platform:name, others as they are", () => {
  const p = mergeProjects([{ name: "web", platform: "vercel" }], [
    { name: "web", platform: "vercel" }, { name: "web", platform: "render" }, { name: "api", platform: "render" },
  ]);
  assert.deepEqual(p.map((x) => x.ref).sort(), ["api", "render:web", "vercel:web"]);
});
