// What the read-only extras show: this month's costs, the deploy freeze, the commits waiting per
// project, and a preview of a rollback. Parsers and texts only (no vscode), so plain node tests them.
// None of this starts anything: it reads `deploys costs`, `freeze --json` and `history --json`.

import { count, t } from "./i18n";
import { age, Project } from "./model";

function rec(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}
function obj(stdout: string): Record<string, unknown> | null {
  try { return rec(JSON.parse(stdout.trim())); } catch { return null; }
}
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
/** Text from a CLI or a commit message is shown as a label: no control characters, not too long. */
export function plain(s: string, max = 120): string {
  const x = s.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  return x.length > max ? x.slice(0, max - 1) + "…" : x;
}

// ---- costs ----

export interface MonthCost {
  /** "2026-11", UTC like the CLI's days. */
  month: string;
  usd: number;
  /** The part of it that is build time. */
  buildUsd: number | null;
  /** Days of the month the CLI could read. */
  days: number;
  /** Some days could not be read: the sum is a floor. */
  partial: boolean;
  currency: string;
}

/** The month of `now` as the CLI names it (UTC). */
export function monthKey(now: Date): string { return now.toISOString().slice(0, 7); }

/** `deploys costs 31`: the sum of the month of `now`. Null when the answer is not the CLI's or has no such month. */
export function parseMonthCost(stdout: string, now: Date = new Date()): MonthCost | null {
  const o = obj(stdout);
  if (!o || !Array.isArray(o.months)) return null;
  const key = monthKey(now);
  const m = o.months.map(rec).find((x) => x && x.month === key);
  const total = m ? num(m.total) : null;
  if (!m || total === null) return null;
  return {
    month: key, usd: total, buildUsd: num(m.build), days: num(m.days) ?? 0,
    partial: (num(o.missingDays) ?? 0) > 0, currency: str(o.currency) ?? "USD",
  };
}

const money = (n: number) => `$${(Math.round(n * 100) / 100).toFixed(2)}`;

/** The status bar text: "$(credit-card) $12.40". A floor gets a "+". */
export function costStatusText(c: MonthCost): string {
  return `$(credit-card) ${money(c.usd)}${c.partial ? "+" : ""}`;
}

export function costTooltip(c: MonthCost): string {
  const lines = [t("Vercel charges in {0}: {1}", c.month, money(c.usd))];
  if (c.buildUsd !== null) lines.push(t("of which builds: {0}", money(c.buildUsd)));
  if (c.partial) lines.push(t("Some days could not be read: the sum is a floor."));
  return lines.join("\n");
}

// ---- deploy freeze ----

export interface FreezeRule { n: number; days: string[] | null; from: string; to: string; reason: string | null }
export interface Freeze { configured: boolean; closedNow: boolean; reason: string | null; rules: FreezeRule[] }

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
      from: str(x.from) ?? "00:00", to: str(x.to) ?? "24:00", reason: str(x.reason),
    });
  }
  return { configured: o.configured === true || rules.length > 0, closedNow: o.closedNow, reason: str(o.reason), rules };
}

/** "fri 15:00–24:00 (release freeze)", or "every day …". */
export function ruleText(r: FreezeRule): string {
  const days = r.days && r.days.length ? r.days.join(",") : t("every day");
  return `${days} ${r.from}–${r.to}${r.reason ? ` (${plain(r.reason, 60)})` : ""}`;
}

/** The freeze status bar item: null when no closed time is set (nothing to show). */
export function freezeStatusText(f: Freeze | null): string | null {
  if (!f || !f.configured) return null;
  return f.closedNow ? t("$(lock) Deploys closed") : t("$(unlock) Deploy window open");
}

export function freezeTooltip(f: Freeze): string {
  const lines: string[] = [];
  lines.push(f.closedNow
    ? (f.reason ? t("Closed now: {0}. A deploy needs --force with a reason.", plain(f.reason, 80)) : t("Closed now. A deploy needs --force with a reason."))
    : t("Deploys are allowed now."));
  for (const r of f.rules) lines.push(`${r.n}. ${ruleText(r)}`);
  return lines.join("\n");
}

// ---- waiting commits per project ----

export interface PendingRow {
  project: Project;
  /** Null: waiting, count unknown. */
  commits: number | null;
  prs: number;
  /** Seconds the oldest waiting commit has waited, or null. */
  waitedSeconds: number | null;
}

/** The waiting projects, most commits first (unknown counts last), then oldest wait, then name. */
export function pendingRows(projects: Project[], now = Date.now() / 1000): PendingRow[] {
  return projects.filter((p) => p.waiting).map((p) => ({
    project: p, commits: p.pendingCommits, prs: p.pendingPRs ?? 0,
    waitedSeconds: p.oldestPendingAt ? Math.max(0, now - p.oldestPendingAt) : null,
  })).sort((a, b) =>
    (b.commits ?? -1) - (a.commits ?? -1) || (b.waitedSeconds ?? -1) - (a.waitedSeconds ?? -1)
    || a.project.name.localeCompare(b.project.name, undefined, { sensitivity: "base" }));
}

export function pendingLabel(r: PendingRow): string {
  return r.commits === null ? t("commits waiting (count unknown)") : count(r.commits, "{0} commit", "{0} commits");
}

/** The lines under a project: what the newest waiting commit says, PRs, how long it waited, the platform. */
export function pendingDetails(r: PendingRow): string[] {
  const lines: string[] = [];
  const p = r.project;
  if (p.headMsg) lines.push(`${p.headSha ? p.headSha.slice(0, 7) + " " : ""}${plain(p.headMsg)}`);
  else if (p.headSha) lines.push(p.headSha.slice(0, 7));
  if (r.prs > 0) lines.push(count(r.prs, "{0} pull request waiting", "{0} pull requests waiting"));
  if (r.waitedSeconds !== null) lines.push(t("waiting for {0}", age(r.waitedSeconds)));
  lines.push(p.platform + (p.repo ? ` · ${p.repo}` : ""));
  return lines;
}

/** The total over the shown projects, for the view's description: "7 commits in 3 projects". */
export function pendingSummary(rows: PendingRow[]): string {
  if (!rows.length) return "";
  const known = rows.reduce((n, r) => n + (r.commits ?? 0), 0);
  const unknown = rows.some((r) => r.commits === null);
  const projects = count(rows.length, "{0} project", "{0} projects");
  return unknown ? t("{0}+ commits in {1}", known, projects) : known === 1 ? t("{0} commit in {1}", known, projects) : t("{0} commits in {1}", known, projects);
}

// ---- rollback preview ----

export interface HistoryRow { when: string | null; target: string | null; state: string | null; commit: string | null; source: string | null }
export interface RollbackPreview { current: HistoryRow; target: HistoryRow }

/** `deploys history <p> n --json`: every row the CLI gives, read as far as it goes. */
export function parseHistory(stdout: string): HistoryRow[] | null {
  let v: unknown;
  try { v = JSON.parse(stdout.trim()); } catch { return null; }
  if (!Array.isArray(v)) return null;
  return v.map(rec).filter((x): x is Record<string, unknown> => !!x).map((x) => ({
    when: str(x.when), target: str(x.target), state: str(x.state), commit: str(x.commit),
    // Vercel says "source", Render "trigger".
    source: str(x.source) ?? str(x.trigger),
  }));
}

const GOOD = /^(ready|live|deactivated)$/i;

/**
 * What a rollback would do, worked out from the history only (newest first): the live deploy is the newest
 * good production one, and the rollback goes to the next good one of a different commit (an older deploy of
 * the same commit would change nothing). An estimate: the rollback command reads the platform again.
 * Null when there is nothing to go back to.
 */
export function rollbackPreview(rows: HistoryRow[]): RollbackPreview | null {
  // Vercel marks previews with a target; Render has no previews in its history.
  const prod = rows.filter((r) => (r.target === null || r.target === "production") && r.state !== null && GOOD.test(r.state));
  const current = prod[0];
  if (!current) return null;
  const target = prod.slice(1).find((r) => !current.commit || r.commit !== current.commit);
  return target ? { current, target } : null;
}

const row = (r: HistoryRow) => [r.commit ?? t("unknown commit"), r.when ? `${r.when} UTC` : null, r.source].filter(Boolean).join(" · ");

export function rollbackPreviewText(name: string, p: RollbackPreview | null): { message: string; detail: string } {
  if (!p) return {
    message: t("{0}: there is no earlier production deploy to go back to.", name),
    detail: t("Read from the newest deploys. Nothing was changed."),
  };
  return {
    message: t("Rolling back {0} would put {1} live again.", name, p.target.commit ?? t("the deploy before")),
    detail: [t("Live now: {0}", row(p.current)), t("Would go back to: {0}", row(p.target)),
      t("An estimate from the deploy history; the rollback reads the platform again. Nothing was changed.")].join("\n"),
  };
}
