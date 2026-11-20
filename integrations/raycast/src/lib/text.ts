// The parts of the extension that need no Raycast API: what the CLI's output means, labels and
// counts. Tested with node --test (test/text.test.ts), like the VS Code extension's model.ts.
import type { ChangedProject } from "./deploys";

export type DeploysErrorKind = "missing" | "auth" | "timeout" | "failed";

export function clean(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/\x1b\[[0-9;]*m/g, "").trim();
}

export function lastLines(s: string, n = 3): string {
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
  // An HTTP status, not any 401 (a commit "Fix #401" or a project named api-403 is no login error).
  /\bHTTP\s*(401|403)\b/i,
  /unauthori[sz]ed/i,
  /invalid token/i,
];

// Only stderr: stdout carries commit messages and project names, which can say anything.
export function classify(stderr: string): DeploysErrorKind {
  return AUTH_PATTERNS.some((re) => re.test(stderr)) ? "auth" : "failed";
}

export function isFailedState(state: string | null | undefined): boolean {
  return /error|fail/i.test(state ?? "");
}

const LABELS: Record<string, string> = {
  vercel: "Vercel",
  render: "Render",
  netlify: "Netlify",
  cloudflare: "Cloudflare",
  amplify: "AWS Amplify",
  digitalocean: "DigitalOcean",
  coolify: "Coolify",
  hook: "Deploy hook",
};

// "Vercel", "AWS Amplify"; an unknown provider id as it is, first letter upper case.
export function platformLabel(p: string): string {
  return LABELS[p] ?? p.charAt(0).toUpperCase() + p.slice(1);
}

export function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

export function commitsText(p: ChangedProject): string {
  if (p.rewritten) return "branch rewritten";
  if (p.pendingCommits == null) return "? commits";
  return plural(p.pendingCommits, "commit") + (p.pendingPartial ? "+" : "");
}

export function prsText(p: ChangedProject): string | undefined {
  if (p.pendingPRs == null || p.pendingPRs === 0) return undefined;
  return plural(p.pendingPRs, "PR");
}

// "4 commits, 2 PRs waiting, the oldest since 3 days" for alerts and toasts.
export function waitingSentence(p: ChangedProject): string {
  const parts = [commitsText(p), prsText(p)].filter(Boolean).join(", ");
  const age = p.oldestPendingAt ? `, oldest from ${new Date(p.oldestPendingAt * 1000).toLocaleString()}` : "";
  return `${parts} waiting${age}.`;
}

// Oldest first: what has waited longest comes first.
export function sortByAge(list: ChangedProject[]): ChangedProject[] {
  return [...list].sort((a, b) => (a.oldestPendingAt ?? Infinity) - (b.oldestPendingAt ?? Infinity));
}

// What `deploys plan --json` says about the next deploy (only the sum is used here).
// What `deploys idle --json` returns per project.
export interface IdleProject {
  name: string;
  platform: string;
  lastAt: number | null; // Unix seconds, null: never deployed
  days: number | null;
}

/** "never deployed" or "142 days idle" (one day: "1 day idle"). */
export function idleText(days: number | null | undefined): string {
  if (days === null || days === undefined) return "never deployed";
  return `${days} ${days === 1 ? "day" : "days"} idle`;
}

export interface PlanTotal {
  builds: number;
  usd: number | null;
  unpriced?: number;
}

// "≈ $1.20" for the sum of the next deploy; "" when there is no estimate. A sum with unpriced
// builds says so ("≈ $1.20 + 1 unpriced"), as the estimate then covers only part of the run.
export function costText(t: PlanTotal | null | undefined): string {
  if (!t || typeof t.usd !== "number" || !Number.isFinite(t.usd) || t.builds <= 0) return "";
  const usd = `≈ $${(Math.round(t.usd * 100) / 100).toFixed(2)}`;
  return (t.unpriced ?? 0) > 0 ? `${usd} + ${t.unpriced} unpriced` : usd;
}

// The environment for `deploys`: an allowlist, like the MCP server's. Everything else of Raycast's
// (other extensions' tokens, model keys, agents) stays out; GIT_ASKPASS and GIT_SSH_COMMAND run programs.
const FOR_CLI = new RegExp(
  "^(?:PATH|HOME|USER|LOGNAME|SHELL|TMPDIR|TERM|TZ|LANG|LANGUAGE|LC_[A-Z_]+|XDG_[A-Z_]+|" +
    "(?:HTTPS?|NO|ALL)_PROXY|(?:https?|no|all)_proxy|SSL_CERT_(?:FILE|DIR)|NODE_EXTRA_CA_CERTS|CURL_CA_BUNDLE|" +
    "DEPLOYS_[A-Z0-9_]+|VERCEL_[A-Z0-9_]+|RENDER_[A-Z0-9_]+|NETLIFY_[A-Z0-9_]+|CLOUDFLARE_[A-Z0-9_]+|CF_[A-Z0-9_]+|" +
    "COOLIFY_[A-Z0-9_]+|DIGITALOCEAN_[A-Z0-9_]+|DO_[A-Z0-9_]+|AWS_[A-Z0-9_]+|GH_[A-Z0-9_]+|GITHUB_TOKEN|GITLAB_[A-Z0-9_]+|" +
    "GIT_TERMINAL_PROMPT|GIT_SSL_CAINFO|GIT_SSL_CAPATH|GIT_CONFIG_NOSYSTEM)$",
);
export function cliEnv(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(env)) if (FOR_CLI.test(k)) out[k] = v;
  return out;
}

// What `deploys plan --json` says per project (the next deploy, as an estimate). Read-only.
export interface PlanProject {
  name: string;
  platform: string;
  action?: string | null;
  usd?: number | null;
}

/** "$1.20" with two decimals; "?" when there is no price. */
export function usdText(usd: number | null | undefined): string {
  return typeof usd === "number" && Number.isFinite(usd) ? `$${(Math.round(usd * 100) / 100).toFixed(2)}` : "?";
}

const NOT_STARTED = new Set(["would-skip", "held-by-rule"]);

/** "about $0.80", or "would not start" for a project the plan leaves out. */
export function planRowText(p: PlanProject): string {
  return NOT_STARTED.has(p.action ?? "") ? "would not start" : `about ${usdText(p.usd)}`;
}

// What `deploys history <project> <n> --json` returns per deploy (only the fields used here).
export interface HistoryEntry {
  when?: string | null;
  state?: string | null;
  commit?: string | null;
  at?: number | null; // Unix seconds
}

const WENT_LIVE = /^(ready|live|succe|success|active)/i;

export interface RollbackPreview {
  current: HistoryEntry | null;
  // The newest earlier deploy that went live: what production would go back to. null: none in the list.
  target: HistoryEntry | null;
}

/** The newest deploy and the one a rollback would restore (newest first, as the CLI lists them). Nothing is rolled back. */
export function rollbackPreview(list: HistoryEntry[] | null | undefined): RollbackPreview {
  const l = Array.isArray(list) ? list : [];
  return { current: l[0] ?? null, target: l.slice(1).find((d) => WENT_LIVE.test(d?.state ?? "")) ?? null };
}

/** "abc1234 · READY · 2 h ago"-style line for one deploy: commit (7 characters), state, and the time when known. */
export function historyLine(d: HistoryEntry): string {
  const when = typeof d.at === "number" && d.at > 0 ? new Date(d.at * 1000).toLocaleString() : (d.when ?? "");
  return [(d.commit ?? "").slice(0, 7), d.state ?? "", when].filter(Boolean).join(" · ");
}
