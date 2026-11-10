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

// One server process; requests in, answers matched by id.
function start(env = {}) {
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
    async init() {
      const r = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
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
check("ledger refuses an argument it does not take", r.error && /does not take "days"/.test(r.text), r.text);
check("a refused argument never reaches deploys", callLog() === "", callLog());
r = await s.call("deploys_explain", { project: "app-web", sha: "abc" });
check("an unknown argument is an error, not ignored", r.error && /sha/.test(r.text) && /project/.test(r.text), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: "80" });
check("lines as a string is refused", r.error && /lines/.test(r.text), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 2001 });
check("lines over 2000 is refused", r.error && /lines/.test(r.text), r.text);
r = await s.call("deploys_explain", { project: ["app-web"] });
check("a project list is refused", r.error && /project/.test(r.text), r.text);
check("refused arguments never reach deploys", callLog() === "", callLog());

// --- build logs: secrets masked ---
r = await s.call("deploys_logs", { project: "secret-app" });
const leaked = ["ghp_abcdefghijklmnop1234", "s3cr3t-value", "hunter2pass", "sk_live_abcdefgh1234", "AKIAABCDEFGHIJKLMNOP",
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", "dbpass", "MIIEvQIBADANBg", "glpat-abcdefgh12345", "abcdefghijklmnopqrstu", "dev@example.com"]
  .filter((x) => r.text.includes(x));
check("logs: secrets are masked", !r.error && leaked.length === 0, leaked.join(", ") + "\n" + r.text);
check("logs: the rest of the log stays", r.text.includes("Build failed: missing module") && r.text.includes("[masked]") && r.text.includes("[masked private key]"), r.text);
check("logs: names before the secret stay", r.text.includes("VERCEL_TOKEN=[masked]") && r.text.includes("postgres://admin:[masked]@db"), r.text);
r = await s.call("deploys_logs", { project: "topkey-app" });
check("logs: a key cut off at the top is masked", !r.error && !r.text.includes("QUJDREVG") && r.text.includes("[masked private key]") && r.text.includes("after the key"), r.text);
r = await s.call("deploys_logs", { project: "bottomkey-app" });
check("logs: a key cut off at the bottom is masked", !r.error && !r.text.includes("QUJDREVG") && r.text.includes("before the key") && r.text.includes("[masked private key]"), r.text);

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
// More than the server collects (4 × max + 64k): the newest part, not the end of the beginning.
r = await s.call("deploys_logs", { project: "big-app" });
check("a log longer than the buffer keeps its real end", !r.error && r.text.trimEnd().endsWith("line 30000 the real error") && r.text.includes("trimmed"), r.text.slice(-200));
check("the kept part starts at a whole line", /^\[… \d+ earlier characters trimmed\]\nline \d+ /.test(r.text), r.text.slice(0, 120));
r = await s.call("deploys_changed");
check("changed that does not fit is still valid JSON", (() => { try { JSON.parse(r.text); return true; } catch { return false; } })(), r.text);
s.stop();

s = start({ DEPLOYS_MCP_MAX_OUTPUT: "400" });
await s.init();
r = await s.call("deploys_changed");
let cj = {};
try { cj = JSON.parse(r.text); } catch {}
check("changed too long: whole entries left out, with a count", cj.total === 2 && cj.truncated === 1 && cj.projects?.length === 1 && cj.projects[0].name === "app-web" && /left out/.test(cj.note), r.text);
r = await s.call("deploys_status");
try { cj = JSON.parse(r.text); } catch { cj = null; }
check("status fits: a plain JSON list", Array.isArray(cj) && cj.length === 3, r.text);
s.stop();

s = start({ DEPLOYS_MCP_TIMEOUT: "1", FAKE_SLEEP_ALL: "20.7" });
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

s = start({ DEPLOYS_MCP_SLOW_TIMEOUT: "1", FAKE_SLEEP_ALL: "20.7" });
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

// --- write tools with DEPLOYS_MCP_ALLOW_DEPLOY=1 ---
// The stand-in lists Render only with a key, as the real list --json does.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_RENDER_KEY: "true" });
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
check("exactly one deploy-json call, for that project", log.filter((l) => l.includes("deploy")).join() === "vercel deploy-json app-web", log.join(" | "));
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
s.stop();

s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_NO_LIST: "1" });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "api" });
const log2 = callLog().trim().split("\n");
check("the platform comes from status when list --json is missing",
  !r.error && JSON.parse(r.text).platform === "render" && log2.includes("list --json") && log2.includes("status --json --no-github"), log2.join(" | "));
s.stop();

process.exit(fails ? 1 : 0);
