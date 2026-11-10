// Tests for integrations/mcp/server.mjs, run from integrations/tests/run.sh.
// A plain JSON-RPC client over stdio talks to the server; the server runs the stand-in
// `deploys` from run.sh (DEPLOYS_BIN), which logs each call to $MCP_CALLS. No network.
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const server = join(here, "..", "mcp", "server.mjs");
const fixture = (f) => JSON.parse(readFileSync(join(here, "..", "..", "tests", "fixtures", "savings", f), "utf8"));
const calls = process.env.MCP_CALLS;
let fails = 0;
const ok = (name) => console.log(`ok   mcp: ${name}`);
const fail = (name, why) => { console.log(`FAIL mcp: ${name}: ${why}`); fails++; };
const check = (name, cond, why = "") => (cond ? ok(name) : fail(name, why));
const callLog = () => { try { return readFileSync(calls, "utf8"); } catch { return ""; } };

// One server process; requests in, answers matched by id. `elicit` answers the server's own
// questions (elicitation/create) with a result; without it the client has no elicitation.
function start(env = {}, { elicit = null } = {}) {
  const child = spawn(process.execPath, [server], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  let buf = "", next = 1;
  const waiting = new Map();
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      if (msg.method === "elicitation/create") {
        s.asked.push(msg.params);
        const result = elicit ? elicit(msg.params) : { action: "decline" };
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");
        continue;
      }
      if (msg.method) continue; // other requests or notifications from the server
      waiting.get(msg.id)?.(msg); waiting.delete(msg.id);
    }
  });
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = next++;
    const t = setTimeout(() => reject(new Error(`no answer to ${method}`)), 15000);
    waiting.set(id, (m) => { clearTimeout(t); resolve(m); });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const s = {
    request,
    asked: [],
    async init() {
      const capabilities = elicit ? { elicitation: {} } : {};
      const r = await request("initialize", { protocolVersion: "2025-06-18", capabilities, clientInfo: { name: "test", version: "0" } });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
      return r.result;
    },
    async names() { return (await request("tools/list")).result.tools.map((t) => t.name).sort(); },
    async call(name, args = {}) {
      const r = (await request("tools/call", { name, arguments: args })).result;
      return { error: r.isError === true, text: r.content.map((c) => c.text).join("\n") };
    },
    stop() { child.kill(); },
    tools: async () => (await request("tools/list")).result.tools,
  };
  return s;
}

const READ = ["deploys_changed", "deploys_doctor", "deploys_explain", "deploys_ledger", "deploys_logs", "deploys_notes", "deploys_simulate", "deploys_status"];

// --- read-only by default ---
let s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "" });
const info = await s.init();
check("initialize names the server", info?.serverInfo?.name === "deploys", JSON.stringify(info?.serverInfo));
check("instructions say read-only", /read-only/.test(info?.instructions ?? ""), info?.instructions);
const names = await s.names();
check("lists the eight read tools", JSON.stringify(names) === JSON.stringify(READ), JSON.stringify(names));
check("no write tool without DEPLOYS_MCP_ALLOW_DEPLOY", !names.includes("deploys_deploy") && !names.includes("deploys_rollback"), JSON.stringify(names));
check("read tools are marked read-only", (await s.tools()).every((t) => t.annotations?.readOnlyHint === true));

let r = await s.call("deploys_changed");
check("changed returns the JSON list", !r.error && JSON.stringify(JSON.parse(r.text).map((p) => p.name)) === '["app-web","api"]', r.text);
r = await s.call("deploys_explain", { project: "app-web" });
check("explain passes the name", !r.error && r.text.includes("explain: app-web"), r.text);
r = await s.call("deploys_notes", { project: "app-web" });
check("notes", !r.error && r.text.includes("## app-web"), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 5 });
check("logs passes lines", !r.error && r.text.trim().split("\n").length === 5, r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 0 });
check("logs refuses 0 lines", r.error, r.text);
r = await s.call("deploys_doctor");
check("doctor", !r.error && JSON.parse(r.text).renderKey === false, r.text);
const listed = await s.tools();
for (const name of ["deploys_simulate", "deploys_ledger"]) {
  const t = listed.find((x) => x.name === name);
  check(`${name} says the numbers are estimates and points to method`, /estimate/i.test(t?.description ?? "") && /`method`/.test(t?.description ?? ""), t?.description);
}
check("simulate takes days 1–90, default 30", JSON.stringify(listed.find((t) => t.name === "deploys_simulate")?.inputSchema?.properties?.days) ===
  JSON.stringify({ type: "integer", minimum: 1, maximum: 90, default: 30, description: "How many past days to count pushes over (1–90, default 30)." }));
check("instructions mention the estimates", /deploys_simulate/.test(info?.instructions ?? "") && /estimate/.test(info?.instructions ?? ""), info?.instructions);

writeFileSync(calls, "");
r = await s.call("deploys_simulate");
let rep = r.error ? {} : JSON.parse(r.text);
const sim = fixture("simulate-report.json");
check("simulate returns the report", rep.kind === "simulate" && rep.estimate === true && rep.method === sim.method &&
  JSON.stringify(rep.projects) === JSON.stringify(sim.projects), r.text.slice(0, 300));
check("simulate defaults to 30 days", callLog().trim() === "simulate --days 30 --json" && rep.days === 30, callLog());
writeFileSync(calls, "");
r = await s.call("deploys_simulate", { days: 7 });
check("simulate passes days", !r.error && JSON.parse(r.text).days === 7 && callLog().trim() === "simulate --days 7 --json", callLog());
writeFileSync(calls, "");
for (const bad of [0, 91, 2.5, "7", "--json", -1]) {
  r = await s.call("deploys_simulate", { days: bad });
  check(`simulate refuses days ${JSON.stringify(bad)}`, r.error && /days/.test(r.text), r.text);
}
check("refused days never reach deploys", callLog() === "", callLog());
r = await s.call("deploys_ledger");
rep = r.error ? {} : JSON.parse(r.text);
const led = fixture("ledger-report.json");
check("ledger returns the report", rep.kind === "ledger" && rep.estimate === true && rep.method === led.method &&
  JSON.stringify(rep.projects) === JSON.stringify(led.projects), r.text.slice(0, 300));
check("ledger runs ledger --json", callLog().trim() === "ledger --json", callLog());
writeFileSync(calls, "");
r = await s.call("deploys_ledger", { days: 7 });
check("ledger passes no arguments on", !callLog().includes("--days"), callLog());

r = await s.call("deploys_deploy", { project: "app-web" });
check("a write tool call is refused without the flag", r.error && r.text.includes("DEPLOYS_MCP_ALLOW_DEPLOY"), r.text);

writeFileSync(calls, "");
for (const bad of ["a b", "x;rm -rf /", "$(id)", "--all", "-x", "", "a/b", "../etc", "ä", "x".repeat(101)]) {
  r = await s.call("deploys_explain", { project: bad });
  check(`rejects the name ${JSON.stringify(bad.slice(0, 12))}`, r.error && /project/.test(r.text), r.text);
}
r = await s.call("deploys_notes", {});
check("a missing name is an error", r.error, r.text);
check("a rejected name never reaches deploys", callLog() === "", callLog());
s.stop();

// --- trimming, timeout, a missing CLI ---
s = start({ DEPLOYS_MCP_MAX_OUTPUT: "100" });
await s.init();
r = await s.call("deploys_logs", { project: "app-web", lines: 1000 });
check("long logs keep the end", r.text.includes("trimmed") && r.text.trimEnd().endsWith("1000") && r.text.length < 200, r.text.slice(0, 200));
s.stop();

s = start({ DEPLOYS_MCP_TIMEOUT: "1", FAKE_SLEEP_ALL: "20.019" });
await s.init();
const t0 = Date.now();
r = await s.call("deploys_doctor");
check("a CLI that does not answer times out", r.error && r.text.includes("did not finish") && Date.now() - t0 < 8000, r.text);
s.stop();

// simulate and ledger get their own, longer timeout.
s = start({ DEPLOYS_MCP_TIMEOUT: "1", FAKE_SLEEP_ALL: "2" });
await s.init();
r = await s.call("deploys_ledger");
check("ledger is not held to the short timeout", !r.error && JSON.parse(r.text).kind === "ledger", r.text.slice(0, 200));
s.stop();

s = start({ DEPLOYS_MCP_SLOW_TIMEOUT: "1", FAKE_SLEEP_ALL: "20.019" });
await s.init();
const t1 = Date.now();
r = await s.call("deploys_simulate");
check("simulate still times out (DEPLOYS_MCP_SLOW_TIMEOUT)", r.error && r.text.includes("within 1 s") && Date.now() - t1 < 8000, r.text);
s.stop();

s = start({ DEPLOYS_BIN: "/nonexistent/deploys" });
await s.init();
r = await s.call("deploys_changed");
check("a missing CLI is a clear error", r.error && r.text.includes("not found"), r.text);
s.stop();

// --- write tools with DEPLOYS_MCP_ALLOW_DEPLOY=1; the human says yes to every question ---
const yes = () => ({ action: "accept", content: { confirm: true } });
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_RENDER_KEY: "true", DEPLOYS_MCP_MAX_DEPLOYS: "20" }, { elicit: yes });
const info2 = await s.init();
const all = await s.tools();
check("the flag adds deploy and rollback", all.some((t) => t.name === "deploys_deploy") && all.some((t) => t.name === "deploys_rollback"));
check("write tools say to ask the human first", all.filter((t) => /deploy$|rollback$/.test(t.name)).every((t) => /ask the human/i.test(t.description)));
check("write tools are marked destructive", all.filter((t) => /deploy$|rollback$/.test(t.name)).every((t) => t.annotations?.destructiveHint === true));
check("instructions say ask first", /ask the human first/.test(info2?.instructions ?? ""), info2?.instructions);

writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
let d = r.error ? {} : JSON.parse(r.text);
check("deploy returns id and url", d.id === "dpl_1" && d.url === "https://app-web-x.vercel.app" && d.platform === "vercel" && d.target === "production", r.text);
const log = callLog().trim().split("\n");
check("the platform comes from list --json", log.includes("list --json") && !log.includes("status --json --no-github"), log.join(" | "));
check("exactly one deploy-json call, for that project", log.filter((l) => l.includes("deploy-json")).join() === "vercel deploy-json app-web", log.join(" | "));
const q = s.asked.at(-1);
check("the server asks the human, naming project, platform and commits", /app-web/.test(q?.message) && /Vercel/.test(q?.message) && /4 commits waiting/.test(q?.message) &&
  q?.requestedSchema?.properties?.confirm?.type === "boolean", JSON.stringify(q));
r = await s.call("deploys_deploy", { project: "app-web", preview: true });
check("preview passes --preview", !r.error && JSON.parse(r.text).target === "preview" && callLog().includes("vercel deploy-json app-web --preview"), r.text);
r = await s.call("deploys_deploy", { project: "api" });
d = r.error ? {} : JSON.parse(r.text);
check("deploys a Render service", d.platform === "render" && d.id === "dep-1" && d.url === null, r.text);
r = await s.call("deploys_deploy", { project: "api", preview: true });
check("no preview on Render", r.error && /preview/.test(r.text), r.text);
r = await s.call("deploys_deploy", { project: "nope" });
check("an unknown project is not deployed", r.error && /No Vercel project/.test(r.text) && !callLog().includes("deploy-json nope"), r.text);
r = await s.call("deploys_deploy", { project: "app-web,api" });
check("one project per call: a list is refused", r.error, r.text);
r = await s.call("deploys_deploy", { project: ["app-web", "api"] });
check("one project per call: an array is refused", r.error, r.text);
r = await s.call("deploys_rollback", { project: "app-web" });
d = r.error ? {} : JSON.parse(r.text);
check("rollback returns the id", d.id === "dpl_0" && d.platform === "vercel", r.text);
check("rollback asks the human too", /Roll back app-web/.test(s.asked.at(-1)?.message ?? ""), JSON.stringify(s.asked.at(-1)));
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "site" });
check("nothing waiting: no deploy without force", r.error && /force/.test(r.text) && !callLog().includes("deploy-json"), r.text);
r = await s.call("deploys_deploy", { project: "site", force: "yes" });
check("force must be a boolean", r.error && /force/.test(r.text), r.text);
s.stop();

// An older CLI without list --json: the platform comes from status.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_RENDER_KEY: "true", FAKE_NO_LIST: "1" }, { elicit: yes });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "api" });
check("the platform comes from status when list --json is missing", !r.error && JSON.parse(r.text).platform === "render" &&
  callLog().includes("status --json --no-github"), r.text + " | " + callLog());
s.stop();

// The human says no, or does not tick the box: nothing starts.
for (const [name, answer] of [["declines", { action: "decline" }], ["cancels", { action: "cancel" }], ["accepts without the tick", { action: "accept", content: { confirm: false } }]]) {
  s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1" }, { elicit: () => answer });
  await s.init();
  writeFileSync(calls, "");
  r = await s.call("deploys_deploy", { project: "app-web" });
  const r2 = await s.call("deploys_rollback", { project: "app-web" });
  check(`the human ${name}: nothing is deployed or rolled back`, r.error && r2.error && /nothing was started/.test(r.text) &&
    !/deploy-json|rollback/.test(callLog()), r.text + " | " + callLog());
  s.stop();
}

// A client that cannot ask: refused, unless DEPLOYS_MCP_CONFIRM=client.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1" });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
check("no elicitation: the write is refused", r.error && /cannot ask/.test(r.text) && !callLog().includes("deploy-json"), r.text);
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", DEPLOYS_MCP_CONFIRM: "client" });
await s.init();
r = await s.call("deploys_deploy", { project: "app-web" });
check("DEPLOYS_MCP_CONFIRM=client trusts the client's approval", !r.error && JSON.parse(r.text).id === "dpl_1" && s.asked.length === 0, r.text);
s.stop();

// At most DEPLOYS_MCP_MAX_DEPLOYS per run, and one at a time.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", DEPLOYS_MCP_MAX_DEPLOYS: "1" }, { elicit: yes });
await s.init();
r = await s.call("deploys_deploy", { project: "app-web" });
const over = await s.call("deploys_deploy", { project: "app-web" });
check("the limit per run stops the second deploy", !r.error && over.error && /DEPLOYS_MCP_MAX_DEPLOYS/.test(over.text), over.text);
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", DEPLOYS_MCP_MAX_DEPLOYS: "5" }, { elicit: yes });
await s.init();
const both = await Promise.all([s.call("deploys_deploy", { project: "app-web" }), s.call("deploys_deploy", { project: "app-web" })]);
check("two deploys at once: the second is refused", both.filter((x) => x.error && /already in progress/.test(x.text)).length === 1 &&
  both.filter((x) => !x.error).length === 1, JSON.stringify(both));
s.stop();

// A start that times out may have started: the text says so and says not to retry.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", DEPLOYS_MCP_WRITE_TIMEOUT: "1", FAKE_DEPLOY_SLEEP: "5" }, { elicit: yes });
await s.init();
r = await s.call("deploys_deploy", { project: "app-web" });
check("a timed-out deploy may have started: check status, do not retry", r.error && /MAY HAVE STARTED/.test(r.text) &&
  /deploys_status/.test(r.text) && /not call it again/.test(r.text), r.text);
s.stop();

// --- masking: logs, notes and explain reach the model without known token shapes ---
s = start({ FAKE_SECRET_LOG: "1" });
await s.init();
r = await s.call("deploys_logs", { project: "app-web" });
check("logs: tokens are masked, the rest stays", !r.error && !/ghp_abcdefgh12345678|hunter2|sk-ant-abc12345678|rnd_abcdefgh123|s3cr3t/.test(r.text) &&
  /\[masked\]/.test(r.text) && /Build ok · Umlaut ä/.test(r.text), r.text);
s.stop();

process.exit(fails ? 1 : 0);
