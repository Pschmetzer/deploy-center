import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { APP_CLI, candidates, childEnv, deployArgs, deployFailure, errorLine, findCli, loadProjects, makeRunner, parseDeploy, projectArgs, urlIn } from "../src/cli";
import { summarize } from "../src/model";
import { scopeProjects } from "../src/repo";

// The bundle lives in out/test/; the fixtures stay in test/fixtures/.
const FAKE = path.resolve(__dirname, "../../test/fixtures/deploys");
const runner = (env: Record<string, string> = {}) => makeRunner(FAKE, childEnv({ ...process.env, ...env }));

test("findCli: setting, then the app, then ~/Applications, then PATH", () => {
  const home = "/h";
  const only = (...ok: string[]) => (p: string) => ok.includes(p);
  const userApp = "/h/Applications/Deploy Center.app/Contents/Resources/deploys";
  assert.deepEqual(candidates({ home, envPath: "/a:/b" }).slice(0, 4), [APP_CLI, userApp, "/a/deploys", "/b/deploys"]);
  assert.equal(findCli({ home, envPath: "/a", exists: only(APP_CLI, userApp, "/a/deploys") }), APP_CLI);
  assert.equal(findCli({ home, envPath: "/a", exists: only(userApp, "/a/deploys") }), userApp);
  assert.equal(findCli({ home, envPath: "/a:/b", exists: only("/b/deploys") }), "/b/deploys");
  assert.equal(findCli({ home, envPath: "/a", exists: only() }), null);
  assert.equal(findCli({ home, setting: "~/bin/deploys", exists: only("/h/bin/deploys", APP_CLI) }), "/h/bin/deploys");
  // A wrong setting is reported as missing, not replaced by another copy behind the user's back.
  assert.equal(findCli({ home, setting: "/nope", exists: only(APP_CLI) }), null);
});

test("findCli finds a real executable on PATH", () => {
  assert.equal(findCli({ home: "/nonexistent", envPath: path.dirname(FAKE) }), FAKE);
});

test("loadProjects: both reads merged; the folder's repo picks its projects", async () => {
  const l = await loadProjects(runner(), 10_000);
  assert.equal(l.failed, false); assert.equal(l.warning, null);
  assert.deepEqual(l.projects.map((p) => p.name), ["worker", "docs", "api", "app-web", "blog", "site"]);
  const mine = scopeProjects(l.projects, ["git@github.com:me/app.git"], "auto");
  assert.equal(mine.matched, true);
  assert.deepEqual(mine.projects.map((p) => p.name), ["worker", "api", "app-web"]);
  assert.deepEqual(summarize(mine.projects), { waiting: 2, commits: 4, commitsPartial: true, building: 0, failed: 1 });
  assert.deepEqual(summarize(l.projects), { waiting: 3, commits: 5, commitsPartial: true, building: 1, failed: 1 });
});

test("loadProjects: a partial read keeps the list and warns", async () => {
  const l = await loadProjects(runner({ FAKE_PARTIAL: "1" }), 10_000);
  assert.equal(l.failed, false);
  assert.equal(l.projects.filter((p) => p.waiting).length, 3);
  assert.equal(l.warning, "render api: branch head unknown");
});

test("loadProjects: changed failing still shows building and failed", async () => {
  const l = await loadProjects(runner({ FAKE_CHANGED_FAIL: "1" }), 10_000);
  assert.equal(l.failed, false);
  assert.equal(l.projects.filter((p) => p.waiting).length, 0);
  assert.equal(l.projects.filter((p) => p.failed).length, 1);
  assert.match(l.warning ?? "", /could not read render: timeout/);
});

test("loadProjects: an older CLI without repo in status still matches waiting projects", async () => {
  const l = await loadProjects(runner({ FAKE_OLD_STATUS: "1" }), 10_000);
  const mine = scopeProjects(l.projects, ["https://github.com/me/app"], "repo");
  assert.deepEqual(mine.projects.map((p) => p.name), ["api", "app-web"]);
});

test("a CLI that does not answer is stopped at the timeout", async () => {
  const t = Date.now();
  const l = await loadProjects(runner({ FAKE_SLEEP: "20.1" }), 500);
  assert.ok(Date.now() - t < 5000, "gave up in time");
  assert.equal(l.failed, true);
  assert.match(l.warning ?? "", /did not answer in time/);
});

test("a timeout also stops what the CLI started (its process group)", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "dc-"));
  try {
    const pidfile = path.join(dir, "pid");
    const r = await runner({ FAKE_SLEEP: "20.3", FAKE_PIDFILE: pidfile })(["changed", "--json"], 500);
    assert.equal(r.timedOut, true);
    const pid = Number(readFileSync(pidfile, "utf8").trim());
    assert.ok(pid > 0, "the child wrote its pid");
    let alive = true;
    for (let i = 0; i < 20 && alive; i++) {
      try { process.kill(pid, 0); await new Promise((res) => setTimeout(res, 100)); } catch { alive = false; }
    }
    assert.equal(alive, false, "the sleep behind the CLI is gone");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a CLI that cannot start is an error, not a hang", async () => {
  const r = await makeRunner("/nonexistent/deploys")(["changed", "--json"], 2000);
  assert.equal(r.code, 1);
  assert.equal(r.timedOut, false);
  assert.match(r.stderr, /ENOENT/);
});

test("arguments are passed as they are, never through a shell", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "dc-"));
  try {
    const log = path.join(dir, "args");
    const name = "x; touch pwned $(id) `id` 'q\"";
    const r = await runner({ FAKE_ARGS_LOG: log })(deployArgs({ platform: "vercel", name }), 5000);
    assert.equal(r.code, 2);
    assert.deepEqual(readFileSync(log, "utf8").split("\n").slice(0, 4), ["3", "vercel", "deploy-json", name]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("deploy start: success and a refused start", async () => {
  const run = runner();
  const ok = await run(deployArgs({ platform: "vercel", name: "app-web" }), 5000);
  assert.deepEqual(parseDeploy(ok.stdout), { id: "dpl_1", url: "https://app-web-abc.vercel.app", state: "QUEUED" });
  const bad = await run(deployArgs({ platform: "render", name: "api" }), 5000);
  assert.equal(bad.code, 1);
  assert.equal(parseDeploy(bad.stdout), null);
  assert.equal(errorLine(bad, "deploy"), "render-x is being started already (wait a minute)");
});

test("logs come back with stdin closed and NO_COLOR set", async () => {
  const r = await runner()(["logs", "worker", "200"], 5000);
  assert.equal(r.code, 0);
  assert.match(r.stdout, /npm ERR! missing script/);
  assert.equal(childEnv({ PATH: "/x" }).NO_COLOR, "1");
  assert.ok(childEnv({ PATH: "/x" }).PATH?.startsWith("/x:"));
});

test("urlIn and errorLine", () => {
  assert.equal(urlIn("https://example.test/a\n"), "https://example.test/a");
  assert.equal(urlIn(""), null);
  assert.equal(errorLine({ code: 1, stdout: "", stderr: "\u001b[31mError:\u001b[0m boom\n\n", timedOut: false }, "x"), "boom");
  assert.equal(errorLine({ code: 3, stdout: "", stderr: "", timedOut: false }, "x"), "x failed (exit 3).");
});

test("projectArgs: logs, notes and open take the ref", () => {
  assert.deepEqual(projectArgs("logs", { ref: "render:web" }, "200"), ["logs", "render:web", "200"]);
  assert.deepEqual(projectArgs("open", { ref: "web" }, "--dashboard"), ["open", "web", "--dashboard"]);
  assert.deepEqual(deployArgs({ platform: "netlify", name: "site" }), ["netlify", "deploy-json", "site"]);
});

test("an observer-mode refusal reaches the message as one line", async () => {
  const r = await runner({ FAKE_OBSERVER: "1" })(deployArgs({ platform: "vercel", name: "app-web" }), 5000);
  assert.equal(r.code, 1);
  assert.match(errorLine(r, "deploy"), /^Observer mode/);
});

test("a deploy start that timed out may have started: the text says so", async () => {
  const r = await runner({ FAKE_SLEEP: "20.2" })(["vercel", "deploy-json", "app-web"], 300);
  assert.equal(r.timedOut, true);
  assert.match(deployFailure(r), /may have started anyway/);
  assert.equal(deployFailure({ code: 1, stdout: "", stderr: "Error: boom", timedOut: false }), "boom");
});
