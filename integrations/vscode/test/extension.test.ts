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
  process.env.DEPLOYS_FAKE_ARGS_LOG = log;
  vs.settings.cliPath = FAKE;
  vs.workspace.workspaceFolders = undefined;
});
afterEach(() => {
  ctl?.dispose(); ctl = null;
  delete process.env.DEPLOYS_FAKE_ARGS_LOG;
  rmSync(dir, { recursive: true, force: true });
});

async function ready(followMs = 5): Promise<Controller> {
  ctl = new Controller(followMs);
  await ctl.refresh();
  await ctl.costLoad;
  await ctl.extrasLoad;
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

test("rollback: exit 0 without a readable answer is not called a failure", async () => {
  const c = await ready();
  process.env.DEPLOYS_FAKE_ROLLBACK_EMPTY = "1";
  try {
    c.locate(); // the runner takes the environment when it is made
    vs.answers.warning.push("Roll back");
    await c.rollback(project(c, "app-web"));
    assert.deepEqual(said("error"), []);
    assert.match(said("warning")[1], /the rollback ran, but its answer could not be read/);
  } finally { delete process.env.DEPLOYS_FAKE_ROLLBACK_EMPTY; }
});

// ---- read-only extras: costs, freeze, waiting commits, rollback preview ----

test("costs and freeze are read at a refresh and shown; nothing deploys or rolls back", async () => {
  const c = await ready();
  assert.match(cliCalls(), /costs\n31/);
  assert.match(cliCalls(), /freeze\n--json/);
  assert.equal(c.costItem.text, "$(credit-card) $12.35");
  assert.equal((c.costItem as unknown as { shown: boolean }).shown, true);
  assert.equal(c.freezeItem.text, "$(unlock) Deploy window open");
  assert.doesNotMatch(cliCalls(), /deploy-json|rollback/);
});

test("a closed freeze says so in the status bar and the tooltip", async () => {
  process.env.DEPLOYS_FAKE_FREEZE_CLOSED = "true";
  try {
    const c = await ready();
    assert.equal(c.freezeItem.text, "$(lock) Deploys closed");
    assert.match(String(c.freezeItem.tooltip), /Closed now: release freeze/);
    assert.match(String((c.status.tooltip as { value: string }).value), /Deploys are closed now/);
  } finally { delete process.env.DEPLOYS_FAKE_FREEZE_CLOSED; }
});

test("without closed times the freeze item stays hidden; the setting turns the costs off", async () => {
  process.env.DEPLOYS_FAKE_FREEZE_NONE = "1";
  vs.settings.showCosts = false;
  try {
    const c = await ready();
    assert.equal((c.freezeItem as unknown as { shown: boolean }).shown, false);
    assert.equal((c.costItem as unknown as { shown: boolean }).shown, false);
    assert.doesNotMatch(cliCalls(), /costs/);
  } finally { delete process.env.DEPLOYS_FAKE_FREEZE_NONE; }
});

test("a failing costs read hides the item and is tried again at the next refresh", async () => {
  process.env.DEPLOYS_FAKE_COSTS_FAIL = "1";
  try {
    const c = await ready();
    assert.equal((c.costItem as unknown as { shown: boolean }).shown, false);
    delete process.env.DEPLOYS_FAKE_COSTS_FAIL;
    c.locate(); // the runner takes the environment when it is made
    await c.refresh(); await c.extrasLoad;
    assert.equal(c.costItem.text, "$(credit-card) $12.35");
  } finally { delete process.env.DEPLOYS_FAKE_COSTS_FAIL; }
});

test("the costs are not read at every refresh", async () => {
  const c = await ready();
  await c.refresh(); await c.extrasLoad;
  assert.equal(cliCalls().split("\n").filter((l) => l === "costs").length, 1);
});

test("the waiting-commits list: most commits first, as plain rows", async () => {
  const c = await ready();
  assert.deepEqual(c.pendingList.map((r) => r.project.name), ["app-web", "blog", "api"]);
  const blog = c.pendingList[1];
  assert.equal(blog.project.headMsg, "Fix <b>login</b> flow");
});

test("rollback preview reads the history, changes nothing, and only a click opens the usual question", async () => {
  const c = await ready();
  await c.rollbackPreview(project(c, "app-web"));
  assert.match(cliCalls(), /history\napp-web\n20\n--json/);
  assert.doesNotMatch(cliCalls(), /rollback/);
  const info = vs.calls.filter((x) => x.kind === "info")[0];
  assert.equal(info.args[0], "Rolling back app-web would put aaaa111 live again.");
  assert.equal(vs.calls.filter((x) => x.kind === "warning").length, 0);
});

test("rollback preview: the button goes on to the usual confirmation; declining that rolls nothing back", async () => {
  const c = await ready();
  const orig = vs.window.showInformationMessage;
  vs.window.showInformationMessage = ((...a: unknown[]) => { vs.calls.push({ kind: "info", args: a }); return Promise.resolve("Roll back…"); }) as never;
  vs.answers.warning.push(undefined);
  try { await c.rollbackPreview(project(c, "app-web")); } finally { vs.window.showInformationMessage = orig; }
  assert.match(said("warning")[0], /Roll back app-web on Vercel\?/);
  assert.doesNotMatch(cliCalls(), /vercel\nrollback/);
});

test("rollback preview for a project that cannot be rolled back says so", async () => {
  const c = await ready();
  c.shown.push({ ...project(c, "blog"), platform: "netlify", name: "nl", ref: "nl" });
  await c.rollbackPreview(c.shown[c.shown.length - 1]);
  assert.match(said("info")[0], /cannot be rolled back from here/);
  assert.doesNotMatch(cliCalls(), /history/);
});

test("the new commands are registered and the status-bar clicks read only", async () => {
  const subs: { dispose(): void }[] = [];
  activate({ subscriptions: subs } as never);
  for (const id of ["deployCenter.rollbackPreview", "deployCenter.showFreeze", "deployCenter.costs"]) assert.ok(vs.commandsRun[id], id);
  for (const s of subs) s.dispose();
});

test("show freeze: the rules in a dialog without buttons", async () => {
  const c = await ready();
  await c.showFreeze();
  const info = vs.calls.filter((x) => x.kind === "info").pop()!;
  assert.match(String(info.args[1].detail), /1\. fri 15:00–24:00 \(release freeze\)/);
  assert.equal(info.args.length, 2);
});
