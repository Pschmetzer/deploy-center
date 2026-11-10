// Tests for integrations/mcp/server.js, run from integrations/tests/run.sh.
// A plain JSON-RPC client over stdio talks to the server; the server runs the stand-in
// `deploys` from run.sh (DEPLOYS_BIN), which logs each call to $MCP_CALLS. No network.
import { spawn } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const mcpDir = join(dirname(fileURLToPath(import.meta.url)), "..", "mcp");
const server = join(mcpDir, "server.js");
const calls = process.env.MCP_CALLS;
let fails = 0;
const ok = (name) => console.log(`ok   mcp: ${name}`);
const fail = (name, why) => { console.log(`FAIL mcp: ${name}: ${why}`); fails++; };
const check = (name, cond, why = "") => (cond ? ok(name) : fail(name, why));
const callLog = () => { try { return readFileSync(calls, "utf8"); } catch { return ""; } };

// One server process; requests in, answers matched by id.
function start(env = {}, cmd = [process.execPath, server]) {
  const child = spawn(cmd[0], cmd.slice(1), { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
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

const READ = ["deploys_changed", "deploys_doctor", "deploys_explain", "deploys_logs", "deploys_notes", "deploys_status"];

// --- read-only by default ---
let s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "" });
const info = await s.init();
check("initialize names the server", info?.serverInfo?.name === "deploys", JSON.stringify(info?.serverInfo));
check("instructions say read-only", /read-only/.test(info?.instructions ?? ""), info?.instructions);
const names = await s.names();
check("lists the six read tools", JSON.stringify(names) === JSON.stringify(READ), JSON.stringify(names));
check("no write tool without DEPLOYS_MCP_ALLOW_DEPLOY", !names.includes("deploys_deploy") && !names.includes("deploys_rollback"), JSON.stringify(names));
check("read tools are marked read-only", (await s.tools()).every((t) => t.annotations?.readOnlyHint === true));

let r = await s.call("deploys_changed");
check("changed returns the JSON list", !r.error && JSON.stringify(JSON.parse(r.text).map((p) => p.name)) === '["app-web","api"]', r.text);
r = await s.call("deploys_explain", { project: "app-web" });
check("explain passes the name", !r.error && r.text.includes("explain: app-web"), r.text);
r = await s.call("deploys_notes", { project: "api" });
check("notes", !r.error && r.text.includes("## Notes for api"), r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 5 });
check("logs passes lines", !r.error && r.text.trim().split("\n").length === 5, r.text);
r = await s.call("deploys_logs", { project: "app-web", lines: 0 });
check("logs refuses 0 lines", r.error, r.text);
r = await s.call("deploys_doctor");
check("doctor", !r.error && JSON.parse(r.text).renderKey === false, r.text);
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

s = start({ DEPLOYS_MCP_TIMEOUT: "1", FAKE_SLEEP_ALL: "20" });
await s.init();
const t0 = Date.now();
r = await s.call("deploys_doctor");
check("a CLI that does not answer times out", r.error && r.text.includes("did not finish") && Date.now() - t0 < 8000, r.text);
s.stop();

s = start({ DEPLOYS_BIN: "/nonexistent/deploys" });
await s.init();
r = await s.call("deploys_changed");
check("a missing CLI is a clear error", r.error && r.text.includes("not found"), r.text);
s.stop();

// --- write tools with DEPLOYS_MCP_ALLOW_DEPLOY=1 ---
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "1" });
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
check("the platform comes from status when list --json is missing", log.includes("list --json") && log.includes("status --json --no-github"), log.join(" | "));
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

// --- what a Claude Desktop extension passes ---
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "true" });
await s.init();
check("the extension's toggle on (true) adds the write tools", (await s.names()).includes("deploys_deploy"));
s.stop();
s = start({ DEPLOYS_MCP_ALLOW_DEPLOY: "false" });
await s.init();
check("the extension's toggle off (false) is read-only", !(await s.names()).includes("deploys_deploy"));
s.stop();
for (const empty of ["", "${user_config.deploys_bin}"]) {
  s = start({ DEPLOYS_BIN: empty });
  await s.init();
  r = await s.call("deploys_changed");
  check(`DEPLOYS_BIN ${JSON.stringify(empty)} falls back to PATH`, !r.error && r.text.includes("app-web"), r.text);
  s.stop();
}

// --- the launcher ---
const launcher = join(mcpDir, "deploys-mcp");
s = start({}, [launcher]);
await s.init();
r = await s.call("deploys_changed");
check("the launcher starts the server", !r.error && r.text.includes("app-web"), r.text);
s.stop();

const tmp = mkdtempSync(join(tmpdir(), "mcp-test-"));
const runLauncher = (env) => new Promise((resolve) => {
  const c = spawn(launcher, [], { env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "pipe"] });
  let err = ""; c.stderr.on("data", (d) => (err += d));
  c.on("close", (code) => resolve({ code, err }));
});
let l = await runLauncher({ DEPLOYS_MCP_NODE: join(tmp, "no-node") });
check("no Node: the launcher says so and exits 1", l.code === 1 && /Node\.js 18 or newer/.test(l.err) && /not a working node/.test(l.err), l.err);
writeFileSync(join(tmp, "node16"), "#!/bin/sh\necho v16.20.2\n"); chmodSync(join(tmp, "node16"), 0o755);
l = await runLauncher({ DEPLOYS_MCP_NODE: join(tmp, "node16") });
check("an old Node is named", l.code === 1 && /found only .*node16 \(v16\)/.test(l.err), l.err);

// --- the bundle, alone, laid out as in the app: Contents/Resources/{deploys,mcp/} ---
const bundle = join(mcpDir, "dist", "server.js");
if (existsSync(bundle)) {
  const res = join(tmp, "Deploy Center.app", "Contents", "Resources");
  mkdirSync(join(res, "mcp"), { recursive: true });
  copyFileSync(bundle, join(res, "mcp", "server.js"));
  copyFileSync(launcher, join(res, "mcp", "deploys-mcp")); chmodSync(join(res, "mcp", "deploys-mcp"), 0o755);
  copyFileSync(process.env.DEPLOYS_BIN, join(res, "deploys")); chmodSync(join(res, "deploys"), 0o755);
  // No deploys on PATH and no node_modules: the launcher must use ../deploys, the bundle its own SDK.
  s = start({ DEPLOYS_BIN: "", PATH: `${dirname(process.execPath)}:/usr/bin:/bin` }, [join(res, "mcp", "deploys-mcp")]);
  await s.init();
  check("the bundle runs alone, without node_modules", JSON.stringify(await s.names()) === JSON.stringify(READ));
  r = await s.call("deploys_changed");
  check("inside the app the launcher uses the bundled deploys", !r.error && r.text.includes("app-web"), r.text);
  s.stop();
} else fail("the bundle was built", `${bundle} is missing`);

// --- the desktop extension's manifest matches the server ---
const manifest = JSON.parse(readFileSync(join(mcpDir, "desktop-extension", "manifest.json"), "utf8"));
const pkg = JSON.parse(readFileSync(join(mcpDir, "package.json"), "utf8"));
check("manifest version is the server's", manifest.version === pkg.version && readFileSync(server, "utf8").includes(`VERSION = "${pkg.version}"`));
check("manifest lists every tool", JSON.stringify(manifest.tools.map((t) => t.name).sort()) === JSON.stringify(all.map((t) => t.name).sort()));
check("manifest env uses its user_config", Object.values(manifest.server.mcp_config.env).every((v) => {
  const k = /^\$\{user_config\.(\w+)\}$/.exec(v)?.[1]; return k && manifest.user_config[k];
}));
check("deploys are off by default in the extension", manifest.user_config.allow_deploy.type === "boolean" && manifest.user_config.allow_deploy.default === false);
rmSync(tmp, { recursive: true, force: true });

process.exit(fails ? 1 : 0);
