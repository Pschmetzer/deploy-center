// Finding the deploys CLI and running it: an argument array (no shell), its own process group
// with a timeout that ends the whole group, and stdin closed so nothing can wait for input.

import { ChildProcess, spawn } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { mergeProjects, parseArray, Project } from "./model";
import { t } from "./i18n";

export const APP_CLI = "/Applications/Deploy Center.app/Contents/Resources/deploys";

function isExecutable(p: string): boolean {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export interface FindOptions {
  setting?: string;
  home?: string;
  envPath?: string;
  exists?: (p: string) => boolean;
}

/** Where to look, in order: the setting, the app in /Applications, in ~/Applications, then PATH. */
export function candidates(o: FindOptions = {}): string[] {
  const home = o.home ?? os.homedir();
  const list: string[] = [];
  const set = (o.setting ?? "").trim();
  if (set) list.push(set.startsWith("~/") ? path.join(home, set.slice(2)) : set);
  list.push(APP_CLI, path.join(home, "Applications/Deploy Center.app/Contents/Resources/deploys"));
  for (const dir of (o.envPath ?? process.env.PATH ?? "").split(path.delimiter)) {
    if (dir) list.push(path.join(dir, "deploys"));
  }
  // Apps opened from the Dock may start with a short PATH; Homebrew's folders are tried too.
  list.push("/opt/homebrew/bin/deploys", "/usr/local/bin/deploys");
  return [...new Set(list)];
}

/** The first candidate that is an executable file, or null. A set but wrong setting is not skipped silently: it is null. */
export function findCli(o: FindOptions = {}): string | null {
  const exists = o.exists ?? isExecutable;
  const set = (o.setting ?? "").trim();
  const list = candidates(o);
  if (set) return exists(list[0]) ? list[0] : null;
  return list.find(exists) ?? null;
}

export interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export type Runner = (args: string[], timeoutMs: number) => Promise<RunResult>;

/** The environment for the CLI: Homebrew's folders on PATH (for jq, gh, vercel), never a colour code. */
export function childEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const parts = (env.PATH ?? "").split(path.delimiter).filter(Boolean);
  for (const d of ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]) if (!parts.includes(d)) parts.push(d);
  return { ...env, PATH: parts.join(path.delimiter), NO_COLOR: "1" };
}

const MAX_OUTPUT = 32 * 1024 * 1024;

/** Ends the CLI and everything it started (vercel, gh, curl): it runs in its own process group. */
function killGroup(child: ChildProcess, signal: NodeJS.Signals): void {
  try {
    if (child.pid) process.kill(-child.pid, signal);
  } catch {
    try { child.kill(signal); } catch { /* gone */ }
  }
}

/**
 * Runs the CLI with an argument array (no shell), stdin closed. At the timeout the whole process
 * group gets SIGTERM, then SIGKILL two seconds later, so no vercel or sleep is left behind.
 */
export function makeRunner(cli: string, env: NodeJS.ProcessEnv = childEnv()): Runner {
  return (args, timeoutMs) =>
    new Promise((resolve) => {
      let child: ChildProcess;
      try {
        child = spawn(cli, args, { detached: true, stdio: ["ignore", "pipe", "pipe"], env, windowsHide: true });
      } catch (e) {
        resolve({ code: 1, stdout: "", stderr: (e as Error).message, timedOut: false });
        return;
      }
      const out: Buffer[] = [], err: Buffer[] = [];
      let size = 0, timedOut = false, done = false, spawnError = "";
      const take = (into: Buffer[]) => (b: Buffer) => {
        size += b.length;
        if (size > MAX_OUTPUT) { killGroup(child, "SIGKILL"); return; }
        into.push(b);
      };
      child.stdout?.on("data", take(out));
      child.stderr?.on("data", take(err));
      let hard: ReturnType<typeof setTimeout> | undefined;
      const timer = setTimeout(() => {
        timedOut = true;
        killGroup(child, "SIGTERM");
        hard = setTimeout(() => killGroup(child, "SIGKILL"), 2000);
      }, timeoutMs);
      const finish = (code: number) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (hard) clearTimeout(hard);
        // Children that outlived a timed-out CLI (a sleep, a stuck curl) go too.
        if (timedOut) killGroup(child, "SIGKILL");
        resolve({ code, stdout: Buffer.concat(out).toString(), stderr: Buffer.concat(err).toString() || spawnError, timedOut });
      };
      child.on("error", (e) => { spawnError = e.message; finish(1); });
      child.on("close", (code) => finish(typeof code === "number" ? code : 1));
    });
}

/**
 * What a deploy start that failed says. A start that timed out may still have reached the
 * platform, so it says so: deploying again at once could start a second build.
 */
export function deployFailure(r: RunResult): string {
  if (r.timedOut) return t("did not answer in time. It may have started anyway: check its state (Refresh) before you deploy again.");
  return errorLine(r, "deploy");
}

/** The last useful line of stderr, for a message: "Error: " and colour codes gone. */
export function errorLine(r: RunResult, what: string): string {
  if (r.timedOut) return t("{0} did not answer in time.", what);
  const line = r.stderr.split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";
  return line.replace(/\u001B\[[0-9;]*m/g, "").replace(/^Error:\s*/, "") || t("{0} failed (exit {1}).", what, r.code);
}

export interface Loaded {
  projects: Project[];
  /** Something could not be read; the list may be short. Null when all was read. */
  warning: string | null;
  /** Nothing could be read at all. */
  failed: boolean;
}

/**
 * Both reads at once: `changed --json` (what waits, from GitHub) and `status --json --no-github`
 * (every project's newest state, no GitHub calls). Either may exit 1 and still print a list.
 */
export async function loadProjects(run: Runner, timeoutMs: number): Promise<Loaded> {
  const [c, s] = await Promise.all([
    run(["changed", "--json"], timeoutMs),
    run(["status", "--json", "--no-github"], timeoutMs),
  ]);
  const changed = parseArray(c.stdout), status = parseArray(s.stdout);
  const warnings: string[] = [];
  if (c.code !== 0 || !changed) warnings.push(errorLine(c, "deploys changed"));
  if (s.code !== 0 || !status) warnings.push(errorLine(s, "deploys status"));
  return {
    projects: mergeProjects(changed, status),
    warning: warnings.length ? [...new Set(warnings)].join(" ") : null,
    failed: !changed && !status,
  };
}

/** The arguments that start one deploy: `deploys <provider> deploy-json <name> [--preview]`. */
export function deployArgs(p: { platform: string; name: string }, preview = false): string[] {
  return [p.platform, "deploy-json", p.name, ...(preview ? ["--preview"] : [])];
}

/** Preview deploys: Vercel only (as the MCP server); a Render service has none here. */
export function canPreview(p: { platform: string }): boolean {
  return p.platform === "vercel";
}

/** Rollback back to the deploy before the current one: Vercel and Render. */
export function canRollback(p: { platform: string }): boolean {
  return p.platform === "vercel" || p.platform === "render";
}

export function rollbackArgs(p: { platform: string; name: string }): string[] {
  return [p.platform, "rollback", p.name];
}

/** logs, notes and open take the name, or platform:name when it is on two platforms. */
export function projectArgs(verb: "logs" | "notes" | "open", p: { ref: string }, ...rest: string[]): string[] {
  return [verb, p.ref, ...rest];
}

/** What a started deploy says: {id, url?, state}. */
export function parseDeploy(stdout: string): { id: string; url: string | null; state: string | null } | null {
  try {
    const v = JSON.parse(stdout.trim());
    if (v && typeof v.id === "string") return { id: v.id, url: typeof v.url === "string" ? v.url : null, state: typeof v.state === "string" ? v.state : null };
  } catch { /* not JSON */ }
  return null;
}

/** `deploys open` opens the browser itself on a Mac and prints nothing; elsewhere it prints the address. */
export function urlIn(stdout: string): string | null {
  const m = /https?:\/\/\S+/.exec(stdout);
  return m ? m[0] : null;
}
