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
