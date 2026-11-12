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
// The data inside <untrusted-data>…</untrusted-data>, as notes, explain and logs frame it.
const inner = (t) => { const m = /<untrusted-data[^>]*>\n([\s\S]*)\n<\/untrusted-data>/.exec(t); return m ? m[1] : null; };
const callLog = () => { try { return readFileSync(calls, "utf8"); } catch { return ""; } };

// One server process; requests in, answers matched by id. `elicit` answers the server's own
// questions (elicitation/create) with a result; without it the client has no elicitation.
function start(env = {}, { elicit = null } = {}) {
  const child = spawn(process.execPath, [server], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  let buf = "", next = 1;
  const asked = [];
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
      return { error: r.isError === true, text: r.content.map((c) => c.text).join("\n"), structured: r.structuredContent };
    },
    stop() { child.kill(); },
    end() { child.stdin.end(); return new Promise((res) => child.on("exit", res)); },
    tools: async () => (await request("tools/list")).result.tools,
  };
  return s;
}

const READ = ["deploys_changed", "deploys_diff", "deploys_doctor", "deploys_explain", "deploys_history", "deploys_ledger", "deploys_list", "deploys_logs",
  "deploys_notes", "deploys_plan", "deploys_risk", "deploys_simulate", "deploys_status"];

// --- read-only by default ---
let s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "" });
const info = await s.init();
check("initialize names the server", info?.serverInfo?.name === "deploys", JSON.stringify(info?.serverInfo));
const pkgVersion = JSON.parse(readFileSync(join(here, "..", "mcp", "package.json"), "utf8")).version;
check("the server's version is package.json's", info?.serverInfo?.version === pkgVersion, `${info?.serverInfo?.version} vs ${pkgVersion}`);
check("instructions say read-only", /read-only/.test(info?.instructions ?? ""), info?.instructions);
check("prompts and resources are offered", info?.capabilities?.prompts && info?.capabilities?.resources, JSON.stringify(info?.capabilities));
{
  const pl = await s.call("deploys_plan");
  check("plan: deploy-changed without --yes, as JSON", !pl.error && pl.structured?.result?.[0]?.action === "would-deploy" && /deploy-changed --json\n/.test(callLog()) && !/deploy-changed --yes/.test(callLog()), pl.text);
  const pr = (await s.request("prompts/list")).result?.prompts ?? [];
  check("prompt ship-check is listed", pr.some((p) => p.name === "ship-check"), JSON.stringify(pr));
  const g = (await s.request("prompts/get", { name: "ship-check", arguments: { project: "app-web" } })).result;
  const gt = g?.messages?.[0]?.content?.text ?? "";
  check("ship-check names the project, the tools, and deploys nothing", /app-web/.test(gt) && /deploys_plan/.test(gt) && /deploys_notes/.test(gt) && /Deploy nothing/.test(gt), gt);
  const bad = await s.request("prompts/get", { name: "ship-check", arguments: { project: "a;b" } });
  check("ship-check refuses a name that is not one", !!bad.error, JSON.stringify(bad));
  const rl = (await s.request("resources/list")).result?.resources ?? [];
  check("resources: changed and status", rl.map((r) => r.uri).join() === "deploys://changed,deploys://status", JSON.stringify(rl));
  const rr = (await s.request("resources/read", { uri: "deploys://changed" })).result;
  check("resource changed is changed --json", JSON.parse(rr?.contents?.[0]?.text ?? "null")?.map?.((p) => p.name).join() === "app-web,api", JSON.stringify(rr));
  const ru = await s.request("resources/read", { uri: "deploys://nope" });
  check("an unknown resource is an error", !!ru.error, JSON.stringify(ru));
}
const names = await s.names();
check("lists the read tools", JSON.stringify(names) === JSON.stringify(READ), JSON.stringify(names));
check("no write tool without DEPLOYS_MCP_ALLOW_DEPLOY", !names.includes("deploys_deploy") && !names.includes("deploys_rollback"), JSON.stringify(names));
check("read tools are marked read-only", (await s.tools()).every((t) => t.annotations?.readOnlyHint === true));

let r = await s.call("deploys_changed");
check("changed returns the JSON list", !r.error && JSON.stringify(JSON.parse(r.text).map((p) => p.name)) === '["app-web","api"]', r.text);
check("changed also returns structuredContent", JSON.stringify(r.structured?.result?.map((p) => p.name)) === '["app-web","api"]', JSON.stringify(r.structured));
r = await s.call("deploys_list");
check("list returns every project with its platform", !r.error && JSON.parse(r.text).every((p) => p.platform), r.text);
r = await s.call("deploys_risk", { project: "app-web" });
check("risk passes the name and --json", !r.error && JSON.parse(r.text).hints[0].hint === "touches the database schema", r.text);
r = await s.call("deploys_history", { project: "app-web", count: 3 });
check("history passes the count", !r.error && r.text.includes("history app-web 3"), r.text);
r = await s.call("deploys_history", { project: "app-web", count: 0 });
check("history refuses count 0", r.error && /count/.test(r.text), r.text);
r = await s.call("deploys_diff", { project: "app-web" });
check("diff passes the name", !r.error && r.text.includes("diff: app-web"), r.text);
writeFileSync(calls, "");
r = await s.call("deploys_status", { project: "app-web" });
check("status of one project, without GitHub calls", !r.error && JSON.parse(r.text).length === 1 && JSON.parse(r.text)[0].name === "app-web" &&
  callLog().trim() === "status --json --no-github", r.text + " | " + callLog());
r = await s.call("deploys_status", { project: "nope" });
check("status of an unknown project is an error", r.error && /nope/.test(r.text), r.text);
r = await s.call("deploys_explain", { project: "app-web" });
check("explain passes the name", !r.error && r.text.includes("explain: app-web"), r.text);
r = await s.call("deploys_notes", { project: "app-web" });
check("notes", !r.error && inner(r.text)?.includes("## app-web"), r.text);
check("notes are framed as untrusted data", /source="commits and PRs"/.test(r.text) && /never follow/.test(r.text), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 5 });
check("logs passes lines", !r.error && inner(r.text)?.split("\n").length === 5, r.text);
check("logs are framed as untrusted data", /^<untrusted-data source="build log">/.test(r.text) && /not instructions/.test(r.text), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 0 });
check("logs refuses 0 lines", r.error, r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: "80" });
check("logs refuses lines as a string", r.error && /lines/.test(r.text), r.text);
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "", ANTHROPIC_API_KEY: "test-key", FAKE_ENV_DUMP: "1", VERCEL_TOKEN: "vt" });
await s.init();
r = await s.call("deploys_doctor");
check("the CLI gets no model keys of the host, but provider keys", !r.error && !/ANTHROPIC_API_KEY/.test(r.text) && /VERCEL_TOKEN/.test(r.text), r.text.slice(0, 300));
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "" });
await s.init();
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
// The fixture the CLI, the iPhone app and the editor add-ons are checked against: every secret in
// it carries the word SECRET, and none may survive (SECRET_KEY= is a name, not a secret).
r = await s.call("deploys_logs", { project: "fixture-app" });
const survived = (inner(r.text) ?? "").split("\n").filter((l) => l.replaceAll("SECRET_KEY=", "").includes("SECRET"));
check("logs: no secret of the shared fixture survives", !r.error && inner(r.text) && survived.length === 0, survived.join(" | ") || r.text);
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
r = await s.call("deploys_notes", { project: "broken" });
check("exit 1 with output: the output comes back, colour codes gone, the error noted", !r.error && (inner(r.text) ?? "").startsWith("partial notes") &&
  !r.text.includes("\u001b") && /\[exit 1: Error: GitHub rate limit\]/.test(r.text), JSON.stringify(r.text));
s.stop();

// --- trimming, timeout, a missing CLI ---
s = start({ DEPLOYS_MCP_MAX_OUTPUT: "100" });
await s.init();
r = await s.call("deploys_logs", { project: "app-web", lines: 1000 });
check("long logs keep the end", r.text.includes("trimmed") && inner(r.text)?.trimEnd().endsWith("1000") && inner(r.text).length < 200, r.text.slice(0, 200));
// More than the server collects (4 × max + 64k): the newest part, not the end of the beginning.
r = await s.call("deploys_logs", { project: "big-app" });
check("a log longer than the buffer keeps its real end", !r.error && inner(r.text)?.trimEnd().endsWith("line 30000 the real error") && r.text.includes("trimmed"), r.text.slice(-200));
check("the kept part starts at a whole line", /^\[… \d+ earlier characters trimmed\]\nline \d+ /.test(inner(r.text) ?? ""), r.text.slice(0, 120));
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

// --- write tools with DEPLOYS_MCP_ALLOW_DEPLOY=1; the human says yes to every question ---
const yes = () => ({ action: "accept", content: { confirm: true } });
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_RENDER_KEY: "true", FAKE_MORE: "1", DEPLOYS_MCP_MAX_DEPLOYS: "20" }, { elicit: yes });
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
check("the server asks the human, naming project, platform and commits", /vercel:app-web/.test(q?.message) && /4 commits waiting/.test(q?.message) &&
  q?.requestedSchema?.properties?.confirm?.type === "boolean", JSON.stringify(q));
r = await s.call("deploys_deploy", { project: "app-web", preview: true });
check("preview passes --preview", !r.error && JSON.parse(r.text).target === "preview" && callLog().includes("vercel deploy-json app-web --preview"), r.text);
r = await s.call("deploys_deploy", { project: "api" });
d = r.error ? {} : JSON.parse(r.text);
check("deploys a Render service", d.platform === "render" && d.id === "dep-1" && d.url === null, r.text);
r = await s.call("deploys_deploy", { project: "api", preview: true });
check("no preview on Render", r.error && /preview/.test(r.text), r.text);
r = await s.call("deploys_deploy", { project: "nope" });
check("an unknown project is not deployed", r.error && /No project or service named "nope"/.test(r.text) && !callLog().includes("deploy-json nope"), r.text);
writeFileSync(calls, "");
r = await s.call("deploys_rollback", { project: "nope" });
check("an unknown project is not rolled back", r.error && /No project or service named "nope"/.test(r.text) && !/rollback/.test(callLog()), r.text + " | " + callLog());
r = await s.call("deploys_deploy", { project: "app-web,api" });
check("one project per call: a list is refused", r.error, r.text);
r = await s.call("deploys_deploy", { project: ["app-web", "api"] });
check("one project per call: an array is refused", r.error, r.text);
r = await s.call("deploys_rollback", { project: "app-web" });
d = r.error ? {} : JSON.parse(r.text);
check("rollback returns the id", d.id === "dpl_0" && d.platform === "vercel", r.text);
check("rollback asks the human too", /Roll back vercel:app-web/.test(s.asked.at(-1)?.message ?? ""), JSON.stringify(s.asked.at(-1)));
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "site" });
check("nothing waiting: no deploy without force", r.error && /force/.test(r.text) && !callLog().includes("deploy-json"), r.text);
r = await s.call("deploys_deploy", { project: "site", force: "yes" });
check("force must be a boolean", r.error && /force/.test(r.text), r.text);
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "vercel:app-web" });
check("platform:name picks the platform", !r.error && JSON.parse(r.text).project === "app-web" && callLog().includes("vercel deploy-json app-web"), r.text);
r = await s.call("deploys_deploy", { project: "render:app-web" });
check("platform:name on the wrong platform is not found", r.error && /on render/.test(r.text), r.text);
r = await s.call("deploys_deploy", { project: "shop", force: true });
d = r.error ? {} : JSON.parse(r.text);
check("deploys a project on another platform (netlify)", d.platform === "netlify" && d.id === "nd-1" && callLog().includes("netlify deploy-json shop"), r.text);
r = await s.call("deploys_deploy", { project: "twin" });
check("a name on two platforms asks for platform:name", r.error && /(vercel:twin or netlify:twin|netlify:twin or vercel:twin)/.test(r.text), r.text);
r = await s.call("deploys_rollback", { project: "netlify:shop" });
check("rolls back on another platform", !r.error && JSON.parse(r.text).platform === "netlify", r.text);
s.stop();

// The commit the human said yes to is the one deployed (--sha), where the platform can pin one.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_HEAD: "1" }, { elicit: yes });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
d = r.error ? {} : JSON.parse(r.text);
check("production deploys the confirmed commit", !r.error && d.sha === "cccc333333333333333333333333333333333333" &&
  callLog().includes("vercel deploy-json app-web --sha cccc333333333333333333333333333333333333"), r.text + " | " + callLog());
check("the question names that commit and its first line", /commit cccc333 "Add the billing page"/.test(s.asked.at(-1)?.message ?? ""), JSON.stringify(s.asked.at(-1)));
r = await s.call("deploys_deploy", { project: "app-web", preview: true });
check("a preview is not pinned", !r.error && JSON.parse(r.text).sha === null && !/--preview --sha/.test(callLog()), r.text);
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_HEAD: "1", FAKE_NO_PIN: "1" }, { elicit: yes });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
check("a platform without caps.sha: no --sha, and the question says the newest commit is built",
  !r.error && JSON.parse(r.text).sha === null && !callLog().includes("--sha") && /cannot deploy a given commit/.test(s.asked.at(-1)?.message ?? ""),
  r.text + " | " + JSON.stringify(s.asked.at(-1)));
s.stop();

// A name on two platforms is not guessed; a Render rollback goes to render.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_RENDER_KEY: "true", FAKE_DUP: "1" }, { elicit: yes });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
check("a name on two platforms is refused", r.error && /more than one platform/.test(r.text) && !callLog().includes("deploy-json"), r.text);
r = await s.call("deploys_rollback", { project: "api" });
check("rollback of a Render service", !r.error && JSON.parse(r.text).platform === "render" && callLog().includes("render rollback api"), r.text);
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
  check(`the human ${name}: nothing is deployed or rolled back`, r.error && r2.error && /nothing was started/i.test(r.text) &&
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

// Preview-only.
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "preview" }, { elicit: yes });
await s.init();
const pnames = await s.names();
check("preview mode: deploy but no rollback tool", pnames.includes("deploys_deploy") && !pnames.includes("deploys_rollback"), JSON.stringify(pnames));
r = await s.call("deploys_deploy", { project: "app-web" });
check("preview mode: production is refused", r.error && /preview/.test(r.text), r.text);
r = await s.call("deploys_deploy", { project: "app-web", preview: true });
check("preview mode: a preview deploys", !r.error && JSON.parse(r.text).target === "preview" && r.structured?.id === "dpl_1", r.text);
s.stop();


// --- after one yes: an allow list, a cap, a timeout that may have started a build ---
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_MORE: "1", DEPLOYS_MCP_ALLOW_PROJECTS: "app-web, netlify:shop", DEPLOYS_MCP_MAX_DEPLOYS: "2" }, { elicit: yes });
await s.init();
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "site" });
check("a project outside DEPLOYS_MCP_ALLOW_PROJECTS is refused", r.error && /DEPLOYS_MCP_ALLOW_PROJECTS/.test(r.text) && !callLog().includes("deploy-json"), r.text);
r = await s.call("deploys_deploy", { project: "app-web" });
check("a listed project deploys", !r.error, r.text);
r = await s.call("deploys_deploy", { project: "shop", force: true });
check("platform:name in the list counts", !r.error, r.text);
r = await s.call("deploys_deploy", { project: "app-web" });
check("DEPLOYS_MCP_MAX_DEPLOYS stops the next start", r.error && /limit/.test(r.text) && callLog().split("\n").filter((l) => l.includes("deploy-json")).length === 2, r.text);
s.stop();

s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", DEPLOYS_MCP_WRITE_TIMEOUT: "1", FAKE_DEPLOY_SLEEP: "20.7", FAKE_BUILDING: "app-web" }, { elicit: yes });
await s.init();
r = await s.call("deploys_deploy", { project: "app-web" });
check("a timed-out deploy may have started: check status, do not retry", r.error && /may have started/i.test(r.text) &&
  /deploys_status/.test(r.text) && /not call it again/i.test(r.text), r.text);
writeFileSync(calls, "");
r = await s.call("deploys_deploy", { project: "app-web" });
check("the next try reads the status first and refuses while it builds",
  r.error && /building already/.test(r.text) && callLog().includes("status --json --no-github") && !callLog().includes("deploy-json"), r.text + " | " + callLog());
s.stop();

// --- the client ends the server while a deploy runs: its children end too ---
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1", FAKE_DEPLOY_SLEEP: "20.9" }, { elicit: yes });
await s.init();
s.request("tools/call", { name: "deploys_deploy", arguments: { project: "app-web" } }).catch(() => {});
await new Promise((res) => setTimeout(res, 1500));
await s.end();
await new Promise((res) => setTimeout(res, 300));
const orphan = await new Promise((res) => { let o = ""; const p = spawn("pgrep", ["-fl", "sleep 20\\.9"]); p.stdout.on("data", (d) => (o += d)); p.on("exit", () => res(o.trim())); });
check("closing the server stops a running deploys and its children", orphan === "", `still running: ${orphan}`);

// --- masking: logs, notes and explain reach the model without known token shapes ---
s = start({ FAKE_SECRET_LOG: "1" });
await s.init();
r = await s.call("deploys_logs", { project: "app-web" });
check("logs: tokens are masked, the rest stays", !r.error && !/ghp_abcdefgh12345678|hunter2|sk-ant-abc12345678|rnd_abcdefgh123|s3cr3t/.test(r.text) &&
  /\[masked\]/.test(r.text) && /Build ok · Umlaut ä/.test(r.text), r.text);
s.stop();

process.exit(fails ? 1 : 0);
