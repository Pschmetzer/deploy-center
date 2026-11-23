// The read-only answers behind the Costs, Journal Search and Guard Status commands and the menu bar:
// what `deploys costs`, `journal export`, `guard status --json` and `freeze --json` print, read into
// plain objects and short texts. No Raycast API here, so `npm test` covers it with node. None of
// these commands starts a build, a deploy or a rollback.

function rec(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}
function obj(stdout: string): Record<string, unknown> | null {
  try {
    return rec(JSON.parse(stdout.trim()));
  } catch {
    return null;
  }
}
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** Text from a log or a commit is shown as a label: no control characters, not too long. */
export function plain(s: string, max = 140): string {
  const x = s
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return x.length > max ? x.slice(0, max - 1) + "…" : x;
}

export function money(n: number): string {
  return `$${(Math.round(n * 100) / 100).toFixed(2)}`;
}

// ---- costs ----

export interface DayCost {
  day: string;
  total: number;
  build: number;
}
export interface ProjectCost {
  name: string;
  build: number;
  /** Builds of the last 7 days, null when not known. */
  builds: number | null;
}
export interface Costs {
  currency: string;
  /** The month of `now` (UTC, as the CLI names its days), or null when no day of it was read. */
  month: { month: string; total: number; build: number | null; days: number } | null;
  /** Days that could not be read: every sum is a floor. */
  missingDays: number;
  days: DayCost[];
  projects: ProjectCost[];
}

export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** `deploys costs 31`: the charges by day and project, and the sum of this month. Null when it is not the CLI's answer. */
export function parseCosts(stdout: string, now: Date = new Date()): Costs | null {
  const o = obj(stdout);
  if (!o || !Array.isArray(o.months) || !Array.isArray(o.days)) return null;
  const key = monthKey(now);
  const m = o.months.map(rec).find((x) => x && x.month === key);
  const total = m ? num(m.total) : null;
  const days: DayCost[] = [];
  for (const d of o.days) {
    const x = rec(d);
    const day = x && str(x.day);
    const t = x && num(x.total);
    if (x && day && t !== null && t !== undefined) days.push({ day, total: t, build: num(x.build) ?? 0 });
  }
  const projects: ProjectCost[] = [];
  for (const p of Array.isArray(o.projects) ? o.projects : []) {
    const x = rec(p);
    const name = x && str(x.name);
    if (x && name) projects.push({ name, build: num(x.build) ?? 0, builds: num(x.builds) });
  }
  return {
    currency: str(o.currency) ?? "USD",
    month: m && total !== null ? { month: key, total, build: num(m.build), days: num(m.days) ?? 0 } : null,
    missingDays: num(o.missingDays) ?? 0,
    days,
    projects,
  };
}

/** "$12.35" for the menu bar title; a "+" when days are missing (the sum is a floor). */
export function monthTitle(c: Costs | null): string | undefined {
  if (!c?.month) return undefined;
  return money(c.month.total) + (c.missingDays > 0 ? "+" : "");
}

/** "$12.35 in 2026-11 (builds $8.10)". */
export function monthSentence(c: Costs): string {
  if (!c.month) return "No charges read for this month yet.";
  const b = c.month.build !== null ? ` (builds ${money(c.month.build)})` : "";
  return `${money(c.month.total)} in ${c.month.month}${b}${c.missingDays > 0 ? ", a floor: some days could not be read" : ""}`;
}

/** Price of one build over the last 7 days, or null when the counts are not known. */
export function perBuild(p: ProjectCost): number | null {
  return p.builds && p.builds > 0 ? p.build / p.builds : null;
}

// ---- journal ----

export interface JournalRow {
  at: string;
  platform: string;
  name: string;
  result: string;
  detail: string;
}

/** RFC 4180: quoted fields with "" and line breaks inside, CRLF or LF between rows. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else field += c;
  }
  if (field !== "" || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((r) => !(r.length === 1 && r[0] === ""));
}

/** `deploys journal export` (CSV: at,platform,name,result,detail), newest first. The ' the CLI puts before a leading = + - @ is taken off. */
export function parseJournal(csv: string): JournalRow[] {
  const rows = parseCsv(csv);
  if (!rows.length || rows[0].join(",") !== "at,platform,name,result,detail") return [];
  const un = (s: string) => (/^'[=+@\t\r-]/.test(s) ? s.slice(1) : s);
  return rows
    .slice(1)
    .filter((r) => r.length >= 5)
    .map((r) => ({ at: un(r[0]), platform: un(r[1]), name: un(r[2]), result: un(r[3]), detail: un(r[4]) }))
    .sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
}

/** Every word of the query must be in the project, platform, result or detail (any case). An empty query keeps all. */
export function searchJournal(rows: JournalRow[], query: string, limit = 200): JournalRow[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const hit = (r: JournalRow) => {
    const hay = `${r.name} ${r.platform} ${r.result} ${r.detail} ${r.at}`.toLowerCase();
    return words.every((w) => hay.includes(w));
  };
  return rows.filter(hit).slice(0, limit);
}

/** The date of the first day to read, `days` back from `now` (UTC), for `journal export --since`. */
export function sinceDate(now: Date, days: number): string {
  return new Date(now.getTime() - days * 86400_000).toISOString().slice(0, 10);
}

// ---- guard ----

export interface GuardAction {
  action: string;
  platform: string;
  project: string | null;
  error: string | null;
}
export interface GuardAllowance {
  platform: string;
  project: string;
  expiresAt: number;
}
export interface Guard {
  enabled: boolean;
  /** Unix seconds, null: never run. */
  lastRun: number | null;
  lastDry: boolean;
  firstRunPending: boolean;
  actions: GuardAction[];
  allowances: GuardAllowance[];
  pathMissing: string[];
}

/** `deploys guard status --json`. Null when it is not the CLI's answer. */
export function parseGuard(stdout: string): Guard | null {
  const o = obj(stdout);
  if (!o || typeof o.enabled !== "boolean") return null;
  const actions: GuardAction[] = [];
  for (const a of Array.isArray(o.lastActions) ? o.lastActions : []) {
    const x = rec(a);
    if (x)
      actions.push({
        action: str(x.action) ?? "?",
        platform: str(x.platform) ?? "",
        project: str(x.project),
        error: str(x.error),
      });
  }
  const allowances: GuardAllowance[] = [];
  for (const a of Array.isArray(o.allowances) ? o.allowances : []) {
    const x = rec(a);
    const exp = x && num(x.expiresAt);
    if (x && exp) allowances.push({ platform: str(x.platform) ?? "", project: str(x.project) ?? "", expiresAt: exp });
  }
  return {
    enabled: o.enabled,
    lastRun: num(o.lastRun),
    lastDry: o.lastDry === true,
    firstRunPending: o.firstRunPending === true,
    actions,
    allowances,
    pathMissing: Array.isArray(o.pathMissing) ? o.pathMissing.filter((x): x is string => typeof x === "string") : [],
  };
}

/** "5 min ago", "3 h ago", "2 d ago". */
export function agoText(unix: number, now: number): string {
  const s = Math.max(0, now - unix);
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

/** "45 min left", "2 h left", "expired". */
export function leftText(unix: number, now: number): string {
  const s = unix - now;
  if (s <= 0) return "expired";
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))} min left`;
  return `${Math.floor(s / 3600)} h left`;
}

export function guardSummary(g: Guard, now: number): string {
  if (!g.enabled) return "off: auto-deploy is not checked on a schedule";
  const last = g.lastRun ? `last run ${agoText(g.lastRun, now)}${g.lastDry ? " (dry run)" : ""}` : "has not run yet";
  return `on, every 30 minutes; ${last}`;
}

// ---- deploy freeze ----

export interface FreezeRule {
  n: number;
  days: string[] | null;
  from: string;
  to: string;
  reason: string | null;
}
export interface Freeze {
  configured: boolean;
  closedNow: boolean;
  reason: string | null;
  rules: FreezeRule[];
}

/** `deploys freeze --json`. */
export function parseFreeze(stdout: string): Freeze | null {
  const o = obj(stdout);
  if (!o || typeof o.closedNow !== "boolean" || !Array.isArray(o.rules)) return null;
  const rules: FreezeRule[] = [];
  for (const r of o.rules) {
    const x = rec(r);
    if (!x) continue;
    rules.push({
      n: num(x.n) ?? rules.length + 1,
      days: Array.isArray(x.days) ? x.days.filter((d): d is string => typeof d === "string") : null,
      from: str(x.from) ?? "00:00",
      to: str(x.to) ?? "24:00",
      reason: str(x.reason),
    });
  }
  return {
    configured: o.configured === true || rules.length > 0,
    closedNow: o.closedNow,
    reason: str(o.reason),
    rules,
  };
}

export function ruleText(r: FreezeRule): string {
  const days = r.days && r.days.length ? r.days.join(",") : "every day";
  return `${days} ${r.from}–${r.to}${r.reason ? ` (${plain(r.reason, 60)})` : ""}`;
}

/** "Closed now (release freeze)", "Open now", "No closed times". */
export function freezeText(f: Freeze | null): string {
  if (!f) return "Not read";
  if (!f.configured) return "No closed times";
  return f.closedNow ? `Closed now${f.reason ? ` (${plain(f.reason, 60)})` : ""}` : "Open now";
}

// ---- timeline: what `deploys timeline --json` prints ----

export interface TimelineEntry {
  at: string;
  platform: string;
  name: string;
  kind: string;
  detail: string;
}

/** The entries of `deploys timeline --json`, newest first; null when the text is not that answer. */
export function parseTimeline(stdout: string): TimelineEntry[] | null {
  const o = obj(stdout);
  if (!o || !Array.isArray(o.entries)) return null;
  const out: TimelineEntry[] = [];
  for (const e of o.entries) {
    const r = rec(e);
    const at = r && str(r.at);
    if (!r || !at) continue;
    out.push({ at, platform: str(r.platform) ?? "", name: str(r.name) ?? "?", kind: str(r.kind) ?? "other", detail: plain(str(r.detail) ?? "") });
  }
  return out;
}
