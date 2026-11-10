// What the deploys CLI prints, read into one list of projects. No vscode here, so it is tested
// with plain node.

/** A provider id as the CLI spells it: vercel, render, netlify, cloudflare, amplify, hook, … */
export type Platform = string;

const LABELS: Record<string, string> = {
  vercel: "Vercel", render: "Render", netlify: "Netlify", cloudflare: "Cloudflare", amplify: "AWS Amplify",
  digitalocean: "DigitalOcean", coolify: "Coolify", hook: "Deploy hook",
};
/** "Vercel", "AWS Amplify"; an unknown provider id as it is, first letter upper case. */
export function platformLabel(p: string): string {
  return LABELS[p] ?? p.charAt(0).toUpperCase() + p.slice(1);
}

export interface Project {
  name: string;
  platform: Platform;
  /** owner/name on GitHub, when known. */
  repo: string | null;
  /** Commits on the branch that are not live. Null: waiting, count unknown. */
  pendingCommits: number | null;
  pendingPRs: number | null;
  /** Unix seconds of the oldest waiting commit. */
  oldestPendingAt: number | null;
  waiting: boolean;
  building: boolean;
  failed: boolean;
  /** The newest attempt's state as the platform spells it (READY, ERROR, build_failed, …). */
  state: string | null;
  /** The name the CLI is given: "name", or "platform:name" when the name is on two platforms. */
  ref: string;
}

/** The newest attempt failed: Vercel ERROR, Render build_failed / update_failed / pre_deploy_failed. */
export function isFailedState(state: string | null | undefined): boolean {
  return !!state && /error|fail/i.test(state);
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
function str(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}
/** Provider ids are lower-case words (docs/PROVIDERS.md); anything else is not a project row. */
function platform(v: unknown): Platform | null {
  return typeof v === "string" && /^[a-z][a-z0-9_-]*$/.test(v) ? v : null;
}

const BUSY = ["queued", "building"];
/**
 * Building and failed from the shared `phase` (queued, building, ready, failed, canceled) when the
 * CLI has it; from the platform's own words otherwise (CLIs before providers).
 */
function phaseOf(row: Record<string, unknown>, state: string | null, fallbackBuilding: boolean): { building: boolean; failed: boolean } {
  const phase = str(row.phase);
  if (phase) return { building: BUSY.includes(phase), failed: phase === "failed" };
  const building = row.building === true || fallbackBuilding;
  return { building, failed: !building && isFailedState(state) };
}

/**
 * A JSON array from the CLI's stdout, or null. The CLI exits 1 when one platform could not be
 * read but still prints what it could read; that list is kept.
 */
export function parseArray(stdout: string): Record<string, unknown>[] | null {
  const t = stdout.trim();
  if (!t) return null;
  try {
    const v = JSON.parse(t);
    return Array.isArray(v) ? v.filter((x) => x && typeof x === "object") : null;
  } catch {
    return null;
  }
}

const key = (p: { platform: string; name: string }) => `${p.platform}\u0000${p.name}`;

/**
 * `changed` is `deploys changed --json` (what waits, with counts; ignored projects left out),
 * `status` is `deploys status --json --no-github` (every project: building, newest state).
 * Either may be null when it could not be read.
 */
export function mergeProjects(
  changed: Record<string, unknown>[] | null,
  status: Record<string, unknown>[] | null,
): Project[] {
  const out = new Map<string, Project>();
  for (const s of status ?? []) {
    const name = str(s.name), plat = platform(s.platform);
    if (!name || !plat) continue;
    const state = str(s.state);
    out.set(key({ platform: plat, name }), {
      name, platform: plat, repo: str(s.repo), ref: name,
      pendingCommits: null, pendingPRs: null, oldestPendingAt: null,
      // Waiting comes only from `changed`: it knows GitHub and leaves ignored projects out.
      waiting: false, ...phaseOf(s, state, false), state,
    });
  }
  for (const c of changed ?? []) {
    const name = str(c.name), plat = platform(c.platform);
    if (!name || !plat) continue;
    const prev = out.get(key({ platform: plat, name }));
    const state = prev?.state ?? str(c.latestState) ?? str(c.lastState);
    out.set(key({ platform: plat, name }), {
      name, platform: plat, ref: name,
      repo: str(c.repo) ?? prev?.repo ?? null,
      pendingCommits: num(c.pendingCommits), pendingPRs: num(c.pendingPRs),
      oldestPendingAt: num(c.oldestPendingAt),
      waiting: true, ...(prev ? { building: prev.building, failed: prev.failed } : phaseOf(c, state, false)), state,
    });
  }
  const list = [...out.values()];
  // A name on two platforms is given as platform:name, which only CLIs with providers read.
  const seen = new Map<string, number>();
  for (const p of list) seen.set(p.name, (seen.get(p.name) ?? 0) + 1);
  for (const p of list) if ((seen.get(p.name) ?? 0) > 1) p.ref = `${p.platform}:${p.name}`;
  return list.sort((a, b) =>
    rank(a) - rank(b) || a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}

/** Failed first, then building, then waiting, then the rest. */
function rank(p: Project): number {
  return p.failed ? 0 : p.building ? 1 : p.waiting ? 2 : 3;
}

export interface Summary {
  waiting: number;
  commits: number;
  /** Some waiting project has an unknown count, so `commits` is a floor. */
  commitsPartial: boolean;
  building: number;
  failed: number;
}

export function summarize(projects: Project[]): Summary {
  const w = projects.filter((p) => p.waiting);
  return {
    waiting: w.length,
    commits: w.reduce((n, p) => n + (p.pendingCommits ?? 0), 0),
    commitsPartial: w.some((p) => p.pendingCommits === null),
    building: projects.filter((p) => p.building).length,
    failed: projects.filter((p) => p.failed).length,
  };
}

/** The status bar text: "⏳ 3 waiting", and building / failed when there are any. */
export function statusText(s: Summary): string {
  const parts: string[] = [];
  if (s.failed) parts.push(`$(error) ${s.failed} failed`);
  if (s.building) parts.push(`$(sync~spin) ${s.building} building`);
  if (s.waiting) parts.push(`⏳ ${s.waiting} waiting`);
  return parts.length ? parts.join("  ") : "$(check) up to date";
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

/** One line per project, for the tree and the quick pick: "4 commits, 1 PR waiting · vercel". */
export function describe(p: Project, now = Date.now() / 1000): string {
  const bits: string[] = [];
  if (p.failed) bits.push(`failed (${p.state})`);
  if (p.building) bits.push("building");
  if (p.waiting) {
    let w = p.pendingCommits === null ? "changes" : plural(p.pendingCommits, "commit");
    if (p.pendingPRs) w += `, ${plural(p.pendingPRs, "PR")}`;
    w += " waiting";
    if (p.oldestPendingAt) w += ` (${age(now - p.oldestPendingAt)})`;
    bits.push(w);
  }
  if (!bits.length) bits.push("up to date");
  bits.push(p.platform);
  return bits.join(" · ");
}

export function age(seconds: number): string {
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))} min`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h`;
  return `${Math.round(seconds / 86400)} d`;
}

export type FollowState = "wait" | "live" | "failed" | "gone";

/**
 * One look at a deploy that was just started. A new build may show up only after a while (the
 * platform queues it), so "live" needs either a build that was seen running and is done now, or
 * a few looks without any build (then the newest state is what there is).
 */
export function followStep(p: Pick<Project, "building" | "failed"> | undefined, seenBuilding: boolean, looks: number): FollowState {
  if (!p) return "gone";
  if (p.building) return "wait";
  if (!seenBuilding && looks < 4) return "wait";
  return p.failed ? "failed" : "live";
}
