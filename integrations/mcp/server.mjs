#!/usr/bin/env node
// deploys-mcp: an MCP server (stdio) that wraps the Deploy Center `deploys` CLI.
//
// Read-only tools always. deploys_deploy and deploys_rollback exist only with
// DEPLOYS_MCP_ALLOW_DEPLOY=1, and each call acts on exactly one project.
// `deploys` is run with an argument array (never a shell), a timeout, and trimmed output.
//
// Env:
//   DEPLOYS_BIN               path to `deploys` (else PATH, else the app bundle)
//   DEPLOYS_MCP_ALLOW_DEPLOY  1 = also offer deploys_deploy and deploys_rollback
//   DEPLOYS_MCP_TIMEOUT       seconds per command (default 90)
//   DEPLOYS_MCP_MAX_OUTPUT    characters returned per call (default 20000)

import { spawn } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const VERSION = "0.1.0";
const NAME_RE = /^[A-Za-z0-9._:-]+$/;
const ALLOW_DEPLOY = process.env.DEPLOYS_MCP_ALLOW_DEPLOY === "1";
const TIMEOUT_MS = posInt(process.env.DEPLOYS_MCP_TIMEOUT, 90) * 1000;
const MAX_OUTPUT = posInt(process.env.DEPLOYS_MCP_MAX_OUTPUT, 20000);

function posInt(v, dflt) {
  const n = Number.parseInt(v ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}

// ---------- finding and running `deploys` ----------

function isExecutable(p) {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function findDeploys(env = process.env) {
  if (env.DEPLOYS_BIN) return isExecutable(env.DEPLOYS_BIN) ? env.DEPLOYS_BIN : null;
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (dir && isExecutable(join(dir, "deploys"))) return join(dir, "deploys");
  }
  const bundle = join("Deploy Center.app", "Contents", "Resources", "deploys");
  for (const p of [join("/Applications", bundle), join(env.HOME || homedir(), "Applications", bundle)]) {
    if (isExecutable(p)) return p;
  }
  return null;
}

class ToolError extends Error {}

// Runs `deploys <args>`. Resolves with { code, stdout, stderr }; a non-zero exit is not a throw
// (changed/status exit 1 when one project could not be read, and still print the rest).
function runDeploys(args, { timeoutMs = TIMEOUT_MS } = {}) {
  const bin = findDeploys();
  if (!bin) {
    throw new ToolError(
      "The deploys CLI was not found. Set DEPLOYS_BIN, put deploys on PATH, or install Deploy Center in /Applications.",
    );
  }
  return new Promise((resolve) => {
    // An argument array, no shell. Its own process group, so a timeout also stops the vercel,
    // gh or curl it started, which would otherwise keep the pipes open.
    const child = spawn(bin, args, { detached: true, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, NO_COLOR: "1" } });
    const cap = 4 * MAX_OUTPUT + 65536;
    let stdout = "", stderr = "", timedOut = false, done = false;
    child.stdout.on("data", (d) => { if (stdout.length < cap) stdout += d; });
    child.stderr.on("data", (d) => { if (stderr.length < cap) stderr += d; });
    const kill = () => { try { process.kill(-child.pid, "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch {} } };
    const timer = setTimeout(() => { timedOut = true; kill(); finish(null); }, timeoutMs);
    const finish = (code) => {
      if (done) return;
      done = true; clearTimeout(timer);
      resolve({ code, timedOut, stdout, stderr });
    };
    child.on("error", (e) => { stderr += String(e.message); finish(127); });
    child.on("close", (code, signal) => finish(code ?? (signal ? 1 : 0)));
  });
}

const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;

// Keeps the head (or the tail, for logs) and says how much was cut.
function trim(text, { keep = "head", max = MAX_OUTPUT } = {}) {
  const s = String(text).replace(ANSI, "");
  if (s.length <= max) return s;
  const cut = s.length - max;
  return keep === "tail"
    ? `[… ${cut} earlier characters trimmed]\n${s.slice(-max)}`
    : `${s.slice(0, max)}\n[… ${cut} more characters trimmed]`;
}

function describeFailure(args, r) {
  if (r.timedOut) return `deploys ${args.join(" ")} did not finish within ${TIMEOUT_MS / 1000} s and was stopped.`;
  const msg = (r.stderr || r.stdout).trim() || "no output";
  return `deploys ${args.join(" ")} exited ${r.code}: ${trim(msg, { max: 4000 })}`;
}

// Runs and returns the text. Output plus a non-zero exit is returned with a note, not as an error.
async function textOf(args, { keep = "head" } = {}) {
  const r = await runDeploys(args);
  if (r.timedOut || (r.code !== 0 && !r.stdout.trim())) throw new ToolError(describeFailure(args, r));
  let out = trim(r.stdout, { keep });
  if (r.code !== 0) out += `\n\n[exit ${r.code}${r.stderr.trim() ? `: ${trim(r.stderr.trim(), { max: 2000 })}` : ""}]`;
  return out;
}

async function jsonOf(args) {
  const r = await runDeploys(args);
  if (r.timedOut || r.code !== 0) throw new ToolError(describeFailure(args, r));
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw new ToolError(`deploys ${args.join(" ")} did not print JSON: ${trim(r.stdout, { max: 1000 })}`);
  }
}

// ---------- argument checks ----------

function checkProject(v) {
  if (typeof v !== "string" || v.length === 0) throw new ToolError("project is required: one project or service name.");
  // A leading "-" would read as an option (--dashboard, --all), so it is refused too.
  if (v.length > 100 || !NAME_RE.test(v) || v.startsWith("-")) {
    throw new ToolError(`Invalid project name ${JSON.stringify(v.slice(0, 120))}: use letters, digits and . _ : - only.`);
  }
  return v;
}

function checkLines(v) {
  if (v === undefined || v === null) return 80;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1 || n > 2000) throw new ToolError("lines must be a whole number from 1 to 2000.");
  return n;
}

// Which platform a name is on. `deploys list --json` (newer CLIs) first, then `status --json
// --no-github`, which every current CLI has and which needs no GitHub calls.
async function platformOf(project) {
  for (const args of [["list", "--json"], ["status", "--json", "--no-github"]]) {
    const r = await runDeploys(args);
    if (r.timedOut || !r.stdout.trim()) continue;
    let list;
    try {
      list = JSON.parse(r.stdout);
    } catch {
      continue;
    }
    if (!Array.isArray(list)) continue;
    const hit = list.filter((p) => p && p.name === project && typeof p.platform === "string");
    if (hit.length > 1) throw new ToolError(`"${project}" is a name on more than one platform; deploy it in Deploy Center.`);
    if (hit.length === 1) return hit[0].platform;
    if (r.code === 0) break; // a full list without it: it does not exist
  }
  throw new ToolError(`No Vercel project or Render service named "${project}" was found.`);
}

// ---------- tools ----------

const projectProp = { type: "string", description: "One project (Vercel) or service (Render) name.", pattern: NAME_RE.source };
const READ = { readOnlyHint: true, destructiveHint: false, openWorldHint: true };

const tools = [
  {
    name: "deploys_changed",
    description:
      "List the projects that have commits or merged PRs on GitHub that are not live yet (deploys changed --json). Read-only. Use it to answer \"what is waiting to go live?\".",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { title: "What is waiting to go live", ...READ },
    run: () => textOf(["changed", "--json"]),
  },
  {
    name: "deploys_status",
    description: "What is building right now and the newest state of every project, including failed ones (deploys status --json). Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { title: "Building or failed", ...READ },
    run: () => textOf(["status", "--json"]),
  },
  {
    name: "deploys_explain",
    description: "Explain why one project is, or is not, counted as changed (deploys explain). Read-only.",
    inputSchema: { type: "object", properties: { project: projectProp }, required: ["project"], additionalProperties: false },
    annotations: { title: "Why changed", ...READ },
    run: (a) => textOf(["explain", checkProject(a.project)]),
  },
  {
    name: "deploys_notes",
    description: "Release notes in Markdown for one project: the commits and PRs between what is live and the branch (deploys notes). Read-only.",
    inputSchema: { type: "object", properties: { project: projectProp }, required: ["project"], additionalProperties: false },
    annotations: { title: "Release notes", ...READ },
    run: (a) => textOf(["notes", checkProject(a.project)]),
  },
  {
    name: "deploys_logs",
    description: "The last lines of the newest build log of one project (deploys logs). Read-only. Use it when a build failed.",
    inputSchema: {
      type: "object",
      properties: { project: projectProp, lines: { type: "integer", minimum: 1, maximum: 2000, default: 80, description: "How many lines (default 80)." } },
      required: ["project"],
      additionalProperties: false,
    },
    annotations: { title: "Build log", ...READ },
    run: (a) => {
      const p = checkProject(a.project);
      return textOf(["logs", p, String(checkLines(a.lines))], { keep: "tail" });
    },
  },
  {
    name: "deploys_doctor",
    description: "Check the tools and logins deploys needs: jq, vercel CLI, gh, a Render key (deploys doctor, JSON). Read-only. No key is printed.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { title: "Check setup", ...READ },
    run: () => textOf(["doctor"]),
  },
];

if (ALLOW_DEPLOY) {
  tools.push(
    {
      name: "deploys_deploy",
      description:
        "Deploy ONE project now: the newest commit of its branch to production, or a preview with preview=true (Vercel only). " +
        "This starts a real build that costs build minutes and can change a live site. " +
        "Ask the human first: show them the project name and what would go live (deploys_notes), and wait for their yes. " +
        "Call only after they said yes to this exact project in this conversation. Never call it for several projects in a row on your own. " +
        "Returns the deploy id and url.",
      inputSchema: {
        type: "object",
        properties: { project: projectProp, preview: { type: "boolean", default: false, description: "A preview deploy instead of production (Vercel only)." } },
        required: ["project"],
        additionalProperties: false,
      },
      annotations: { title: "Deploy one project", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
      run: async (a) => {
        const p = checkProject(a.project);
        if (a.preview !== undefined && typeof a.preview !== "boolean") throw new ToolError("preview must be true or false.");
        const preview = a.preview === true;
        const platform = await platformOf(p);
        if (platform === "render" && preview) throw new ToolError(`${p} is a Render service; Render has no preview deploys here.`);
        if (platform !== "vercel" && platform !== "render") throw new ToolError(`${p} is on ${platform}, which this server cannot deploy.`);
        const args = [platform, "deploy-json", p, ...(preview ? ["--preview"] : [])];
        const d = await jsonOf(args);
        return JSON.stringify(
          { project: p, platform, target: preview ? "preview" : "production", id: d.id ?? null, url: d.url ?? null, state: d.state ?? null },
          null,
          2,
        );
      },
    },
    {
      name: "deploys_rollback",
      description:
        "Roll ONE project's production back to the deploy that was live before the current one. " +
        "This changes a live site. Ask the human first and call only after they said yes to this exact project. " +
        "Returns the id (and url when known) of the deploy that is live again.",
      inputSchema: { type: "object", properties: { project: projectProp }, required: ["project"], additionalProperties: false },
      annotations: { title: "Roll back one project", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
      run: async (a) => {
        const p = checkProject(a.project);
        const platform = await platformOf(p);
        if (platform !== "vercel" && platform !== "render") throw new ToolError(`${p} is on ${platform}, which this server cannot roll back.`);
        const d = await jsonOf([platform, "rollback", p]);
        return JSON.stringify({ project: p, platform, id: d.id ?? null, url: d.url ?? null, state: d.state ?? null }, null, 2);
      },
    },
  );
}

// ---------- the server ----------

const server = new Server(
  { name: "deploys", version: VERSION },
  {
    capabilities: { tools: {} },
    instructions:
      "Deploy Center: Vercel and Render projects with auto-deploy off, deployed by hand. " +
      "Use deploys_changed to see what is waiting to go live and deploys_status for builds. " +
      (ALLOW_DEPLOY
        ? "deploys_deploy and deploys_rollback change live sites: always ask the human first, one project per call."
        : "This server is read-only: it cannot deploy. Tell the human to deploy in Deploy Center or with `deploys`."),
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map(({ run, ...t }) => t),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = tools.find((t) => t.name === req.params.name);
  if (!tool) {
    const why = /^deploys_(deploy|rollback)$/.test(req.params.name)
      ? " Deploying is off: the server was started without DEPLOYS_MCP_ALLOW_DEPLOY=1."
      : "";
    return { isError: true, content: [{ type: "text", text: `Unknown tool ${req.params.name}.${why}` }] };
  }
  try {
    const text = await tool.run(req.params.arguments ?? {});
    return { content: [{ type: "text", text }] };
  } catch (e) {
    const text = e instanceof ToolError ? e.message : `Unexpected error: ${e?.message ?? e}`;
    return { isError: true, content: [{ type: "text", text }] };
  }
});

await server.connect(new StdioServerTransport());
