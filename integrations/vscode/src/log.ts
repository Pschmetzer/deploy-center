import { platformLabel } from "./model";

// Reading a build log: the first error block, and a prompt to hand it to an AI. The same rules
// as the Mac app (app/LogTools.swift), so both copy the same excerpt.

const errorPattern = /\b(error|errors|failed|failure|fatal|exception|traceback)\b|\berr!|cannot find|not found|exited with \d+/i;
const harmless = /\b(0|no|zero) (errors?|failed|failures?)\b|\berrors?: 0\b|\bfailed: 0\b|cache not found|build cache|no cache found|\bif not found\b|deprecat|\bwarn(ing)?\b/i;

/** Whole words, so ErrorBoundary.tsx or onError is not a failure; "0 errors" is not one either. */
export function isErrorLine(line: string): boolean {
  return errorPattern.test(line) && !harmless.test(line);
}

const ansi = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;
/** Colour codes out, and a line of minified code cut to something a reader can use. */
export function clean(line: string, max = 400): string {
  const l = line.replace(ansi, "");
  return l.length > max ? l.slice(0, max) + " …" : l;
}

const secrets: [RegExp, string][] = [
  [/\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/g, "[GITHUB TOKEN]"],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, "[API KEY]"],
  [/\brnd_[A-Za-z0-9]{16,}/g, "[RENDER KEY]"],
  [/\bAKIA[0-9A-Z]{16}\b/g, "[AWS KEY]"],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/g, "[SLACK TOKEN]"],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[JWT]"],
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [HIDDEN]"],
  [/\b([A-Z0-9_]*(token|secret|password|passwd|api_?key|private_?key)[A-Z0-9_]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/gi, "$1$3[HIDDEN]"],
  [/(:\/\/[^/\s:@]+:)[^@\s/]+@/gi, "$1[HIDDEN]@"],
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
export function aiPrompt(p: { name: string; platform: string; repo: string | null; state: string | null }, log: string): string {
  const { text } = firstErrorBlock(log);
  let head = `The ${platformLabel(p.platform)} deploy of "${p.name}" failed.`;
  if (p.repo) head += ` Repo: ${p.repo}.`;
  if (p.state) head += ` Status: ${maskSecrets(p.state)}.`;
  const f = fence(text);
  return `${head}\n\nBuild log (first error):\n${f}\n${text}\n${f}\n\nFind the cause and propose a fix.`;
}
