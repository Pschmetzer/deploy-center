// What the deploys CLI prints, read into one list of projects. No vscode here, so it is tested
// with plain node.

export type Platform = "vercel" | "render";

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
function platform(v: unknown): Platform | null {
  return v === "vercel" || v === "render" ? v : null;
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
    const building = s.building === true;
    out.set(key({ platform: plat, name }), {
      name, platform: plat, repo: str(s.repo),
      pendingCommits: null, pendingPRs: null, oldestPendingAt: null,
      // Waiting comes only from `changed`: it knows GitHub and leaves ignored projects out.
      waiting: false, building, failed: !building && isFailedState(state), state,
    });
  }
  for (const c of changed ?? []) {
    const name = str(c.name), plat = platform(c.platform);
    if (!name || !plat) continue;
    const prev = out.get(key({ platform: plat, name }));
    const state = prev?.state ?? str(c.latestState) ?? str(c.lastState);
    const building = prev?.building ?? c.building === true;
    out.set(key({ platform: plat, name }), {
      name, platform: plat,
      repo: str(c.repo) ?? prev?.repo ?? null,
      pendingCommits: num(c.pendingCommits), pendingPRs: num(c.pendingPRs),
      oldestPendingAt: num(c.oldestPendingAt),
      waiting: true, building, failed: !building && isFailedState(state), state,
    });
  }
  return [...out.values()].sort((a, b) =>
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
