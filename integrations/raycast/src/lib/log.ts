import { platformLabel } from "./text";

// Reading a build log: the first error block, and a prompt to hand it to an AI. The same rules
// as the Mac app (app/LogTools.swift) and the VS Code extension (integrations/vscode/src/log.ts,
// kept the same by integrations/tests/run.sh), so all copy the same excerpt. Imports only ./text,
// so the unit tests run without the Raycast API.

const errorPattern =
  /\b(error|errors|failed|failure|fatal|exception|traceback)\b|\berr!|cannot find|not found|exited with \d+/i;
const harmless =
  /\b(0|no|zero) (errors?|failed|failures?)\b|\berrors?: 0\b|\bfailed: 0\b|cache not found|build cache|no cache found|\bif not found\b|deprecat|\bwarn(ing)?\b/i;

/** Whole words, so ErrorBoundary.tsx or onError is not a failure; "0 errors" is not one either. */
export function isErrorLine(line: string): boolean {
  return errorPattern.test(line) && !harmless.test(line);
}

// eslint-disable-next-line no-control-regex
const ansi = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;
/** Colour codes out, and a line of minified code cut to something a reader can use. */
export function clean(line: string, max = 400): string {
  const l = line.replace(ansi, "");
  return l.length > max ? l.slice(0, max) + " …" : l;
}

// The same rules as the MCP server (integrations/mcp/server.mjs, SECRET_RULES), so a log copied
// here is masked like one an agent reads there. Order matters: key blocks first, then known
// prefixes (sk-ant- before sk-), then names that say secret.
const secrets: [RegExp, string][] = [
  // A private key: whole, cut off at the bottom (BEGIN without END: the 80-line excerpt may end
  // inside it), or cut off at the top (END without BEGIN).
  [
    /-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/g,
    "[PRIVATE KEY]",
  ],
  [/-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*$/g, "[PRIVATE KEY]"],
  [/(?:^[A-Za-z0-9+/=]{8,}\r?\n)*[A-Za-z0-9+/=\\]*-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----/gm, "[PRIVATE KEY]"],
  [/\b(gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,})/g, "[GITHUB TOKEN]"],
  [/\bglpat-[A-Za-z0-9_-]{8,}/g, "[GITLAB TOKEN]"],
  [/\bsk-ant-[A-Za-z0-9_-]{8,}/g, "[API KEY]"],
  [/\bsk-[A-Za-z0-9_-]{8,}/g, "[API KEY]"],
  [/\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}/g, "[STRIPE KEY]"],
  [/\bwhsec_[A-Za-z0-9]{8,}/g, "[WEBHOOK SECRET]"],
  [/\bAIza[A-Za-z0-9_-]{20,}/g, "[GOOGLE KEY]"],
  [/\bnpm_[A-Za-z0-9]{20,}/g, "[NPM TOKEN]"],
  [/\brnd_[A-Za-z0-9]{8,}/g, "[RENDER KEY]"],
  [/\b(?:AKIA|ASIA)[A-Z0-9]{12,}/g, "[AWS KEY]"],
  [/\bxox[abprs]-[A-Za-z0-9-]{8,}/g, "[SLACK TOKEN]"],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+/g, "[JWT]"],
  // NAME=value, NAME: value, "name": "value", Authorization: Bearer x, for names that say secret.
  [
    /\b([A-Za-z0-9_.-]*?(?:token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key|private[_-]?key|_key|authorization|auth|credentials?|dsn)["']?\s*[:=]\s*)((?:bearer|basic|token|bot)\s+)?("[^"]*"|'[^']*'|[^\s"',;]+)/gi,
    "$1$2[HIDDEN]",
  ],
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [HIDDEN]"],
  // --token x, --token=x (vercel, npm and most CLIs).
  [/(--(?:token|password|api-key|secret)(?:=|\s+))[^\s"']+/gi, "$1[HIDDEN]"],
  [/(:\/\/[^/\s:@]+:)[^@\s/]+@/gi, "$1[HIDDEN]@"],
  [/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "[EMAIL]"],
];
/** Keys and tokens a build may print, replaced before a log leaves the editor. */
export function maskSecrets(text: string): string {
  return secrets.reduce((t, [re, to]) => t.replace(re, to), text);
}

/** A Markdown fence longer than any run of backticks in the text, so the log cannot close it. */
export function fence(text: string): string {
  let longest = 0;
  for (const m of text.matchAll(/`+/g)) longest = Math.max(longest, m[0].length);
  return "`".repeat(Math.max(3, longest + 1));
}

/**
 * The first error and what follows it: from 10 lines before the first error line, 80 lines at
 * most. Without an error line, the last 40 lines. Cleaned and with secrets masked.
 */
export function firstErrorBlock(log: string): { text: string; found: boolean } {
  const lines = log.split(/\r?\n/).map((l) => clean(l));
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  const i = lines.findIndex(isErrorLine);
  const from = Math.max(0, (i >= 0 ? i : lines.length - 40) - (i >= 0 ? 10 : 0));
  return { text: maskSecrets(lines.slice(from, from + 80).join("\n")), found: i >= 0 };
}

/** A ready prompt for Claude Code, Cursor or any chat: what failed and the first error block. */
export function aiPrompt(
  p: { name: string; platform: string; repo: string | null; state: string | null },
  log: string,
): string {
  const { text } = firstErrorBlock(log);
  let head = `The ${platformLabel(p.platform)} deploy of "${p.name}" failed.`;
  if (p.repo) head += ` Repo: ${p.repo}.`;
  if (p.state) head += ` Status: ${maskSecrets(p.state)}.`;
  const f = fence(text);
  return `${head}\n\nBuild log (first error):\n${f}\n${text}\n${f}\n\nFind the cause and propose a fix.`;
}
