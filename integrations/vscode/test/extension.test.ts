// The controller (extension.ts) against the stand-in CLI and a stand-in `vscode`: confirmation,
// the double-start guard, deploying a repo's projects, failures, and what is copied.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { activate, Controller } from "../src/extension";
import * as vs from "./fake-vscode";

const FAKE = path.resolve(__dirname, "../../test/fixtures/deploys");
let dir = "", log = "", ctl: Controller | null = null;

beforeEach(() => {
  vs.reset();
  dir = mkdtempSync(path.join(tmpdir(), "dc-ext-"));
  log = path.join(dir, "args.log");
  process.env.FAKE_ARGS_LOG = log;
  vs.settings.cliPath = FAKE;
  vs.workspace.workspaceFolders = undefined;
});
afterEach(() => {
  ctl?.dispose(); ctl = null;
  delete process.env.FAKE_ARGS_LOG;
  rmSync(dir, { recursive: true, force: true });
});

async function ready(followMs = 5): Promise<Controller> {
  ctl = new Controller(followMs);
  await ctl.refresh();
  return ctl;
}
const project = (c: Controller, name: string) => { const p = c.shown.find((x) => x.name === name); assert.ok(p, name); return p; };
const cliCalls = () => (existsSync(log) ? readFileSync(log, "utf8") : "");
const said = (kind: string) => vs.calls.filter((c) => c.kind === kind).map((c) => String(c.args[0]));
async function until(cond: () => boolean, ms = 3000): Promise<void> {
  const end = Date.now() + ms;
  while (!cond()) { if (Date.now() > end) throw new Error("timed out"); await new Promise((r) => setTimeout(r, 10)); }
}

test("activate registers every command of package.json", () => {
  const pkg = JSON.parse(readFileSync(path.resolve(__dirname, "../../package.json"), "utf8"));
  const subs: { dispose(): void }[] = [];
  activate({ subscriptions: subs } as never);
  const ids = (pkg.contributes.commands as { command: string }[]).map((c) => c.command);
  for (const id of ids) assert.ok(vs.commandsRun[id], `${id} is registered`);
  for (const s of subs) s.dispose();
});

test("a cancelled confirmation starts nothing", async () => {
  const c = await ready();
  vs.answers.warning.push(undefined);
  await c.deploy(project(c, "app-web"));
  assert.match(said("warning")[0], /Deploy app-web to production on Vercel\?/);
  assert.doesNotMatch(cliCalls(), /deploy-json/);
});

test("a confirmed deploy starts it, then follows it to live", async () => {
  const c = await ready();
  vs.answers.warning.push("Deploy");
  await c.deploy(project(c, "app-web"));
  assert.match(cliCalls(), /vercel\ndeploy-json\napp-web/);
  assert.equal(said("info")[0], "app-web: started (QUEUED)");
  await until(() => said("info").includes("app-web is live."));
});

test("a second click while the first dialog is open opens no second one", async () => {
  const c = await ready();
  let answer: (v: string | undefined) => void = () => {};
  const orig = vs.window.showWarningMessage;
  vs.window.showWarningMessage = () => new Promise((r) => { answer = r; });
  try {
    const first = c.deploy(project(c, "app-web"));
    await c.deploy(project(c, "app-web"));
    assert.deepEqual(said("info"), ["app-web is being started already."]);
    answer(undefined); await first;
  } finally { vs.window.showWarningMessage = orig; }
});

test("a failed start shows the CLI's reason", async () => {
  const c = await ready();
  vs.answers.warning.push("Deploy");
  await c.deploy(project(c, "api"));
  assert.deepEqual(said("error"), ["api: render-x is being started already (wait a minute)"]);
});

test("deploy this repo: needs a folder whose remote matches", async () => {
  const c = await ready();
  await c.deployRepo();
  assert.deepEqual(said("info"), ["No project deploys from this folder's repo."]);
});

test("deploy this repo: one confirmation, then each waiting project; failures are named", async () => {
  const repo = path.join(dir, "repo");
  execFileSync("git", ["init", "-q", repo]);
  execFileSync("git", ["-C", repo, "remote", "add", "origin", "git@github.com:me/app.git"]);
  vs.workspace.workspaceFolders = [{ uri: { scheme: "file", fsPath: repo } }];
  const c = await ready();
  assert.equal(c.matched, true);
  vs.answers.warning.push("Deploy");
  await c.deployRepo();
  assert.match(said("warning")[0], /Deploy 2 projects of this repo/);
  assert.match(cliCalls(), /app-web/); assert.match(cliCalls(), /render\ndeploy-json\napi/);
  assert.match(said("error")[0], /^1 started, 1 failed to start\. api: /);
});

test("copy for AI: the first error block of the log", async () => {
  const c = await ready();
  await c.copyForAi(project(c, "worker"));
  assert.match(vs.clipboardText.value, /npm ERR! missing script: build/);
  assert.doesNotMatch(vs.clipboardText.value, /\u001B\[/);
});

test("no CLI: the status bar says so and the menu offers the way out", async () => {
  vs.settings.cliPath = path.join(dir, "nope");
  const c = await ready();
  assert.deepEqual(c.shown, []);
  vs.answers.pick.push(undefined);
  await c.menu();
  const pick = vs.calls.find((x) => x.kind === "pick");
  assert.ok(pick && (pick.args[0] as string[]).some((l) => l.includes("Get Deploy Center")));
});

test("dispose stops a deploy that is being followed", async () => {
  const c = await ready(60_000);
  vs.answers.warning.push("Deploy");
  await c.deploy(project(c, "app-web"));
  c.dispose(); ctl = null;
  // Nothing is left to keep the test process alive: the 60 s pause was cleared (node --test
  // would otherwise wait for it).
});

test("preview: Vercel only, asked first, production not followed", async () => {
  const c = await ready();
  vs.answers.warning.push("Deploy preview");
  await c.deployPreview(project(c, "app-web"));
  assert.match(cliCalls(), /deploy-json\napp-web\n--preview/);
  assert.deepEqual(said("info"), ["app-web: preview started (QUEUED)"]);
  await c.deployPreview(project(c, "api"));
  assert.match(said("info")[1], /no preview deploys here/);
});

test("rollback: asked first; the CLI's reason when it cannot", async () => {
  const c = await ready();
  vs.answers.warning.push(undefined);
  await c.rollback(project(c, "app-web"));
  assert.doesNotMatch(cliCalls(), /rollback/);
  vs.answers.warning.push("Roll back");
  await c.rollback(project(c, "app-web"));
  assert.match(said("warning")[1], /Roll back app-web on Vercel\?/);
  assert.deepEqual(said("info"), ["app-web: rolled back to dpl_0 (READY)"]);
  vs.answers.warning.push("Roll back");
  await c.rollback(project(c, "api"));
  assert.deepEqual(said("error"), ["api: no earlier deploy of api"]);
});

test("the project menu offers preview and rollback where the platform has them", async () => {
  const c = await ready();
  vs.answers.pick.push(undefined);
  await c.projectMenu(project(c, "app-web"));
  const labels = vs.calls.find((x) => x.kind === "pick")!.args[0] as string[];
  assert.ok(labels.some((l) => l.includes("Deploy preview")) && labels.some((l) => l.includes("Roll back")));
});
