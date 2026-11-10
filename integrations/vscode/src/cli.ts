// Finding the deploys CLI and running it: execFile with an argument array (no shell), a timeout,
// and stdin closed so nothing can wait for input.

import { execFile } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { mergeProjects, parseArray, Project } from "./model";

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

export function makeRunner(cli: string, env: NodeJS.ProcessEnv = childEnv()): Runner {
  return (args, timeoutMs) =>
    new Promise((resolve) => {
      const child = execFile(cli, args, { timeout: timeoutMs, killSignal: "SIGTERM", maxBuffer: 32 * 1024 * 1024, env, windowsHide: true },
        (err, stdout, stderr) => {
          const e = err as (NodeJS.ErrnoException & { killed?: boolean; signal?: string; code?: number | string }) | null;
          const timedOut = !!e && e.killed === true && e.signal === "SIGTERM";
          const code = !e ? 0 : typeof e.code === "number" ? e.code : 1;
          resolve({ code, stdout: String(stdout), stderr: String(stderr || (e && !timedOut && typeof e.code === "string" ? e.message : "")), timedOut });
        });
      child.stdin?.end();
    });
}

/** The last useful line of stderr, for a message: "Error: " and colour codes gone. */
export function errorLine(r: RunResult, what: string): string {
  if (r.timedOut) return `${what} did not answer in time.`;
  const line = r.stderr.split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";
  return line.replace(/\u001B\[[0-9;]*m/g, "").replace(/^Error:\s*/, "") || `${what} failed (exit ${r.code}).`;
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

/** The arguments that start one deploy. */
export function deployArgs(p: { platform: string; name: string }): string[] {
  return [p.platform, "deploy-json", p.name];
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
