import { getPreferenceValues } from "@raycast/api";
import { execFile } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

// What `deploys changed --json` returns per project (only the fields used here).
export interface ChangedProject {
  name: string;
  platform: string; // vercel, render, netlify, cloudflare, amplify, digitalocean, coolify, hook, …
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
  platform: string; // vercel, render, netlify, cloudflare, amplify, digitalocean, coolify, hook, …
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

export type DeploysErrorKind = "missing" | "auth" | "timeout" | "failed";

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
function clean(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/\x1b\[[0-9;]*m/g, "").trim();
}

function lastLines(s: string, n = 3): string {
  return clean(s)
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(-n)
    .join("\n");
}

const AUTH_PATTERNS = [
  /not logged in/i,
  /vercel login/i,
  /No Render API key/i,
  /Render did not accept/i,
  /gh auth login/i,
  /\b(401|403)\b/,
  /unauthori[sz]ed/i,
  /invalid token/i,
];

function classify(stderr: string): DeploysErrorKind {
  return AUTH_PATTERNS.some((re) => re.test(stderr)) ? "auth" : "failed";
}

export interface RunResult {
  stdout: string;
  stderr: string;
  code: number;
}

// Runs deploys with an argument array (no shell), a timeout and the wider PATH.
// Resolves for every exit code; rejects only when it could not run or ran out of time.
export function run(args: string[], timeout = TIMEOUT.read): Promise<RunResult> {
  const bin = findDeploys();
  return new Promise((resolve, reject) => {
    execFile(
      bin,
      args,
      {
        timeout,
        killSignal: "SIGTERM",
        maxBuffer: 16 * 1024 * 1024,
        env: { ...process.env, PATH: searchPath(), NO_COLOR: "1", TERM: "dumb" },
      },
      (error, stdout, stderr) => {
        const out = String(stdout ?? "");
        const err = String(stderr ?? "");
        if (error) {
          const e = error as NodeJS.ErrnoException & { killed?: boolean; signal?: string; code?: number | string };
          if (e.code === "ENOENT" || e.code === "EACCES") {
            reject(new DeploysError("missing", `Could not start ${bin}: ${e.message}`));
            return;
          }
          if (e.killed || e.signal === "SIGTERM") {
            reject(
              new DeploysError(
                "timeout",
                `deploys ${args.join(" ")} did not finish within ${Math.round(timeout / 1000)} s. A platform or GitHub may be slow; try again.`,
              ),
            );
            return;
          }
          resolve({ stdout: out, stderr: err, code: typeof e.code === "number" ? e.code : 1 });
          return;
        }
        resolve({ stdout: out, stderr: err, code: 0 });
      },
    );
  });
}

function failure(args: string[], r: RunResult): DeploysError {
  const msg = lastLines(r.stderr) || lastLines(r.stdout) || `deploys ${args.join(" ")} ended with code ${r.code}`;
  return new DeploysError(classify(r.stderr + r.stdout), msg.replace(/^Error:\s*/gm, ""));
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

export function changed(): Promise<JsonResult<ChangedProject[]>> {
  return runJson<ChangedProject[]>(["changed", "--json"]);
}

export function status(): Promise<JsonResult<StatusProject[]>> {
  return runJson<StatusProject[]>(["status", "--json"]);
}

export async function deploy(p: { name: string; platform: string }): Promise<DeployStarted> {
  const { data } = await runJson<DeployStarted>([p.platform, "deploy-json", p.name], TIMEOUT.deploy);
  // A start is a deploy id. Anything else ({} or a list) is not "started", whatever the exit code.
  if (!data || typeof data !== "object" || Array.isArray(data) || typeof (data as { id?: unknown }).id !== "string") {
    throw new Error(`deploys ${p.platform} deploy-json ${p.name} gave no deploy id`);
  }
  return data;
}

export function releaseNotes(name: string): Promise<string> {
  return runText(["notes", name], TIMEOUT.read);
}

// `deploys open` opens the address itself on a Mac; elsewhere it prints it. The printed address
// (if any) is returned so the caller can open it.
export async function openProject(name: string, dashboard: boolean): Promise<string | undefined> {
  const out = await runText(dashboard ? ["open", name, "--dashboard"] : ["open", name]);
  return out.match(/https?:\/\/\S+/)?.[0];
}

export function deployCenterURL(name: string): string {
  return `deploycenter://select?project=${encodeURIComponent(name)}`;
}

export function isFailedState(state: string | null | undefined): boolean {
  return /error|fail/i.test(state ?? "");
}

// The same labels as the VS Code extension (integrations/vscode/src/model.ts).
const LABELS: Record<string, string> = {
  vercel: "Vercel", render: "Render", netlify: "Netlify", cloudflare: "Cloudflare", amplify: "AWS Amplify",
  digitalocean: "DigitalOcean", coolify: "Coolify", hook: "Deploy hook",
};
export function platformLabel(p: string): string {
  return LABELS[p] ?? p.charAt(0).toUpperCase() + p.slice(1);
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}
