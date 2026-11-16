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

// The same rules as the MCP server (integrations/mcp/server.mjs, SECRET_RULES), so a log copied
// here is masked like one an agent reads there. Order matters: key blocks first, then known
// prefixes (sk-ant- before sk-), then names that say secret.
const secrets: [RegExp, string][] = [
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
  [/\bdop_v1_[A-Za-z0-9]{16,}/g, "[DIGITALOCEAN TOKEN]"],
  [/\bnfp_[A-Za-z0-9]{16,}/g, "[NETLIFY TOKEN]"],
  [/\b(?:sbp_[A-Za-z0-9]{16,}|sb_secret_[A-Za-z0-9_-]{8,})/g, "[SUPABASE KEY]"],
  [/\bhf_[A-Za-z0-9]{20,}/g, "[HUGGING FACE TOKEN]"],
  [/\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/g, "[SENDGRID KEY]"],
  [/\bre_[A-Za-z0-9]{20,}/g, "[RESEND KEY]"],
  [/\bsntrys_[A-Za-z0-9+/=_-]{20,}/g, "[SENTRY TOKEN]"],
  [/\b[0-9]{1,9}\|[A-Za-z0-9]{40}\b/g, "[COOLIFY TOKEN]"],
  [/\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b/g, "[TELEGRAM TOKEN]"],
  [/https:\/\/(?:hooks\.slack\.com\/services|(?:discord|discordapp)\.com\/api\/webhooks)\/[A-Za-z0-9_/.-]+/g, "[WEBHOOK URL]"],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+/g, "[JWT]"],
  // NAME=value, NAME: value, "name": "value", Authorization: Bearer x, for names that say secret.
  [/\b([A-Za-z0-9_.-]*?(?:token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key|private[_-]?key|[_-]key|accountkey|authorization|auth|credentials?|dsn)["']?\s*[:=]\s*)((?:bearer|basic|token|bot)\s+)?("[^"]*"|'[^']*'|[^\s"',;]+)/gi, "$1$2[HIDDEN]"],
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [HIDDEN]"],
  // Whole cookies, and the signature and credential parts of a signed URL (S3, Azure SAS, GCS).
  [/\b((?:set-cookie|cookie)\s*:\s*).+/gi, "$1[HIDDEN]"],
  [/([?&](?:sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential)=)[^&\s"']+/gi, "$1[HIDDEN]"],
  // --token x, --token=x (vercel, npm and most CLIs).
  [/(--(?:token|password|api-key|secret)(?:=|\s+))[^\s"']+/gi, "$1[HIDDEN]"],
  [/(:\/\/[^/\s:@]+:)[^/\s]+@(?=[^@/\s]+)/gi, "$1[HIDDEN]@"],
  [/\b(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "[EMAIL]"],
];
/** Keys and tokens a build may print, replaced before a log leaves the editor. */
const MAX_LINE = 4000;
const PEM_BEGIN = /-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/;
const PEM_END = /-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/;
const B64_LINE = /^[A-Za-z0-9+/=]{8,}\r?$/;

// One line longer than MAX_LINE is cut before the rules run: the NAME=value rule is quadratic on
// a line like "a.a.a.a" (40 000 characters took 34 s). The cut line says so.
function maskLine(line: string): string {
  const cut = line.length > MAX_LINE;
  const s = secrets.reduce((t, [re, to]) => t.replace(re, to), cut ? line.slice(0, MAX_LINE) : line);
  return cut ? `${s} [… ${line.length - MAX_LINE} more characters in this line, not scanned]` : s;
}

export function maskSecrets(text: string): string {
  // Private keys line by line with a small state: whole, cut off at the bottom (BEGIN without
  // END), or cut off at the top (END without BEGIN: the base64 lines above it go too).
  const out: string[] = [];
  let inKey = false;
  for (const line of text.split("\n")) {
    if (inKey) {
      if (PEM_END.test(line)) inKey = false;
      continue;
    }
    const b = line.search(PEM_BEGIN);
    if (b >= 0) {
      const rest = line.slice(b);
      const end = PEM_END.exec(rest);
      if (end) {
        out.push(maskLine(line.slice(0, b)) + "[PRIVATE KEY]" + maskLine(rest.slice(end.index + end[0].length)));
      } else {
        out.push(maskLine(line.slice(0, b)) + "[PRIVATE KEY]");
        inKey = true;
      }
      continue;
    }
    const end = PEM_END.exec(line);
    if (end) {
      while (out.length && B64_LINE.test(out[out.length - 1])) out.pop();
      out.push("[PRIVATE KEY]" + maskLine(line.slice(end.index + end[0].length)));
      continue;
    }
    out.push(maskLine(line));
  }
  return out.join("\n");
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
