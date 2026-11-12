import { getPreferenceValues } from "@raycast/api";
import { ChildProcess, spawn } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { DeploysErrorKind, classify, clean, lastLines } from "./text";

// Pure helpers (no Raycast API) live in ./text, so they can be tested with node --test.
export { isFailedState, platformLabel, plural } from "./text";
export type { DeploysErrorKind } from "./text";

// A provider id as the CLI spells it: vercel, render, netlify, cloudflare, amplify, hook, …
export type Platform = string;

// What `deploys changed --json` returns per project (only the fields used here).
export interface ChangedProject {
  name: string;
  platform: Platform;
  // The name, or platform:name when the name is on two platforms (set here, not by the CLI).
  projectRef: string;
  repo?: string | null;
  ref?: string | null;
  pendingCommits?: number | null;
  pendingPRs?: number | null;
  pendingPartial?: boolean;
  oldestPendingAt?: number | null; // Unix seconds
  headMsg?: string | null;
  headAt?: number | null;
  lastAt?: number | null;
  rewritten?: boolean;
  compareStatus?: string | null;
}

// What `deploys status --json` returns per project.
export interface StatusProject {
  name: string;
  platform: Platform;
  projectRef: string;
  building: boolean;
  state: string | null;
  changed: boolean;
}

// What `deploys vercel|render deploy-json <name>` prints when a deploy started.
export interface DeployStarted {
  id: string;
  url?: string;
  serviceId?: string;
  state?: string;
}

export class DeploysError extends Error {
  constructor(
    readonly kind: DeploysErrorKind,
    message: string,
  ) {
    super(message);
    this.name = "DeploysError";
  }
}

interface Preferences {
  deploysPath?: string;
  extraPath?: string;
}

const APP_CLI = "Deploy Center.app/Contents/Resources/deploys";

// Timeouts per kind of call. Reading every project asks Vercel, Render and GitHub.
export const TIMEOUT = {
  read: 120_000,
  deploy: 180_000,
  // deploy-changed starts one project after the other.
  many: 600_000,
  quick: 60_000,
};

function expandHome(p: string): string {
  return p === "~" || p.startsWith("~/") ? join(homedir(), p.slice(1)) : p;
}

function isExecutable(p: string): boolean {
  try {
    if (!statSync(p).isFile()) return false;
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Raycast starts commands with a short PATH. deploys needs jq, vercel and gh, which usually sit
// in Homebrew's folders, so those are always added, plus whatever the preference names.
export function searchPath(): string {
  const { extraPath } = getPreferenceValues<Preferences>();
  const extra = (extraPath ?? "")
    .split(":")
    .map((s) => s.trim())
    .filter(Boolean)
    .map(expandHome);
  const parts = [
    ...extra,
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    join(homedir(), ".local/bin"),
    ...(process.env.PATH ?? "").split(delimiter),
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ];
  return [...new Set(parts.filter(Boolean))].join(delimiter);
}

// The preference first, then the copy inside the app, then PATH.
export function findDeploys(): string {
  const { deploysPath } = getPreferenceValues<Preferences>();
  const fromPref = deploysPath?.trim();
  if (fromPref) {
    const p = expandHome(fromPref);
    if (isExecutable(p)) return p;
    throw new DeploysError(
      "missing",
      `The path in the extension's preferences (${p}) is not an executable deploys. Fix it, or clear it to search the usual places.`,
    );
  }
  const candidates = [
    join("/Applications", APP_CLI),
    join(homedir(), "Applications", APP_CLI),
    ...searchPath()
      .split(delimiter)
      .map((dir) => join(dir, "deploys")),
  ];
  const found = candidates.find(isExecutable);
  if (found) return found;
  throw new DeploysError(
    "missing",
    "The deploys CLI was not found. Install Deploy Center in /Applications, or set the path to deploys in the extension's preferences.",
  );
}

// The CLI colours "Error:" on a terminal; strip any escape codes that slip through.

export interface RunResult {
  stdout: string;
  stderr: string;
  code: number;
}

const MAX_OUTPUT = 16 * 1024 * 1024;

// The CLI runs in its own process group: a timeout ends it and what it started (vercel, gh, curl).
function killGroup(child: ChildProcess, signal: NodeJS.Signals) {
  try {
    if (child.pid) process.kill(-child.pid, signal);
  } catch {
    try {
      child.kill(signal);
    } catch {
      // gone already
    }
  }
}

// Runs deploys with an argument array (no shell), stdin closed, a timeout and the wider PATH.
// Resolves for every exit code; rejects only when it could not run or ran out of time.
export function run(args: string[], timeout = TIMEOUT.read): Promise<RunResult> {
  const bin = findDeploys();
  return new Promise((resolve, reject) => {
    let child: ChildProcess;
    try {
      child = spawn(bin, args, {
        detached: true,
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, PATH: searchPath(), NO_COLOR: "1", TERM: "dumb" },
      });
    } catch (e) {
      reject(new DeploysError("missing", `Could not start ${bin}: ${(e as Error).message}`));
      return;
    }
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let size = 0;
    let timedOut = false;
    let done = false;
    const take = (into: Buffer[]) => (b: Buffer) => {
      size += b.length;
      if (size > MAX_OUTPUT) killGroup(child, "SIGKILL");
      else into.push(b);
    };
    child.stdout?.on("data", take(out));
    child.stderr?.on("data", take(err));
    let hard: ReturnType<typeof setTimeout> | undefined;
    const timer = setTimeout(() => {
      timedOut = true;
      killGroup(child, "SIGTERM");
      hard = setTimeout(() => killGroup(child, "SIGKILL"), 2000);
    }, timeout);
    const end = () => {
      done = true;
      clearTimeout(timer);
      if (hard) clearTimeout(hard);
    };
    child.on("error", (e: NodeJS.ErrnoException) => {
      if (done) return;
      end();
      reject(new DeploysError("missing", `Could not start ${bin}: ${e.message}`));
    });
    child.on("close", (code) => {
      if (done) return;
      end();
      if (timedOut) {
        killGroup(child, "SIGKILL");
        reject(
          new DeploysError(
            "timeout",
            `deploys ${args.join(" ")} did not finish within ${Math.round(timeout / 1000)} s. A platform or GitHub may be slow; try again.`,
          ),
        );
        return;
      }
      resolve({
        stdout: Buffer.concat(out).toString(),
        stderr: Buffer.concat(err).toString(),
        code: typeof code === "number" ? code : 1,
      });
    });
  });
}

function failure(args: string[], r: RunResult): DeploysError {
  const msg = lastLines(r.stderr) || lastLines(r.stdout) || `deploys ${args.join(" ")} ended with code ${r.code}`;
  return new DeploysError(classify(r.stderr), msg.replace(/^Error:\s*/gm, ""));
}

export interface JsonResult<T> {
  data: T;
  // Set when deploys answered but also said some of it could not be read (exit code 1 with a list).
  warning?: string;
  warningKind?: DeploysErrorKind;
}

// Runs a --json command. A list that comes with errors on stderr is kept, with the errors as a warning:
// deploys leaves out what it could not read and says so.
export async function runJson<T>(args: string[], timeout = TIMEOUT.read): Promise<JsonResult<T>> {
  const r = await run(args, timeout);
  let data: T | undefined;
  try {
    data = r.stdout.trim() ? (JSON.parse(r.stdout) as T) : undefined;
  } catch {
    data = undefined;
  }
  if (data === undefined) throw failure(args, r);
  if (r.code !== 0 || r.stderr.trim()) {
    const warning = lastLines(r.stderr, 4).replace(/^Error:\s*/gm, "");
    if (warning) return { data, warning, warningKind: classify(r.stderr) };
  }
  return { data };
}

// Runs a command for its text output. Any exit code other than 0 is an error.
export async function runText(args: string[], timeout = TIMEOUT.quick): Promise<string> {
  const r = await run(args, timeout);
  if (r.code !== 0) throw failure(args, r);
  return clean(r.stdout);
}

// notes, open and logs take the name, or platform:name when the name is on two platforms (as the
// VS Code extension does), so a twin never opens or reads the other platform's project.
// `all` is every project (from status), since a list of waiting ones may hold only one twin.
export function withRefs<T extends { name: string; platform: string }>(
  list: Omit<T, "projectRef">[],
  all: { name: string; platform: string }[] = list,
): (T & { projectRef: string })[] {
  const count = new Map<string, number>();
  const seen = new Set<string>();
  for (const p of [...all, ...list]) {
    const k = `${p.platform}/${p.name}`;
    if (seen.has(k)) continue;
    seen.add(k);
    count.set(p.name, (count.get(p.name) ?? 0) + 1);
  }
  return list.map(
    (p) =>
      ({ ...p, projectRef: (count.get(p.name) ?? 0) > 1 ? `${p.platform}:${p.name}` : p.name }) as T & {
        projectRef: string;
      },
  );
}

export async function changed(): Promise<JsonResult<ChangedProject[]>> {
  // Every project's name and platform too (no GitHub calls), to know which names are on two
  // platforms. Without it, only the waiting list itself is counted.
  const [r, all] = await Promise.all([
    runJson<Omit<ChangedProject, "projectRef">[]>(["changed", "--json"]),
    runJson<{ name: string; platform: string }[]>(["status", "--json", "--no-github"]).then(
      (s) => (Array.isArray(s.data) ? s.data : []),
      () => [],
    ),
  ]);
  return { ...r, data: withRefs<ChangedProject>(r.data, all) };
}

export async function status(): Promise<JsonResult<StatusProject[]>> {
  const r = await runJson<Omit<StatusProject, "projectRef">[]>(["status", "--json"]);
  return { ...r, data: withRefs<StatusProject>(r.data) };
}

// `deploys <platform> deploy-json <name>`: the CLI's provider id as it is (vercel, netlify, …).
export async function deploy(p: { name: string; platform: string }): Promise<DeployStarted> {
  const { data } = await runJson<DeployStarted>([p.platform, "deploy-json", p.name], TIMEOUT.deploy);
  // A start is a deploy id. Anything else ({} or a list) is not "started", whatever the exit code.
  if (!data || typeof data !== "object" || Array.isArray(data) || typeof (data as { id?: unknown }).id !== "string") {
    throw new Error(`deploys ${p.platform} deploy-json ${p.name} gave no deploy id`);
  }
  return data;
}

// What `deploys deploy-changed --json` lists (without --yes) and reports (with --yes).
export interface DeployChangedRow {
  platform: Platform;
  name: string;
  action: "would-deploy" | "started" | "failed" | "skipped";
  reason?: string | null;
  id?: string | null;
  url?: string | null;
}

// Several projects at once go through the CLI's own deploy-changed, as the daily job does: one run
// with its rules (freeze, deploy window, start lock, journal). It takes no names, so it first
// shows what it would start; if that is not exactly the confirmed list, nothing starts.
export async function deployChanged(
  confirmed: { name: string; platform: string }[],
): Promise<JsonResult<DeployChangedRow[]>> {
  const key = (p: { name: string; platform: string }) => `${p.platform}/${p.name}`;
  const plan = await runJson<DeployChangedRow[]>(["deploy-changed", "--json"], TIMEOUT.read);
  const want = new Set(confirmed.map(key));
  const got = new Set(plan.data.map(key));
  const same = want.size === got.size && [...want].every((k) => got.has(k));
  if (!same) {
    throw new DeploysError(
      "failed",
      "What waits changed since the list was shown (a push or a finished build). Nothing was started; refresh and confirm again.",
    );
  }
  return runJson<DeployChangedRow[]>(["deploy-changed", "--yes", "--json"], TIMEOUT.many);
}

// The last lines of the newest build log (deploys logs). Raw: mask it before it leaves Raycast.
export function buildLog(ref: string, lines = 200): Promise<string> {
  return runText(["logs", ref, String(lines)], TIMEOUT.read);
}

export function releaseNotes(ref: string): Promise<string> {
  return runText(["notes", ref], TIMEOUT.read);
}

// `deploys open` opens the address itself on a Mac; elsewhere it prints it. The printed address
// (if any) is returned so the caller can open it.
export async function openProject(ref: string, dashboard: boolean): Promise<string | undefined> {
  const out = await runText(dashboard ? ["open", ref, "--dashboard"] : ["open", ref]);
  return out.match(/https?:\/\/\S+/)?.[0];
}

export function deployCenterURL(name: string): string {
  return `deploycenter://select?project=${encodeURIComponent(name)}`;
}
