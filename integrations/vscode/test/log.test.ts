import assert from "node:assert/strict";
import { test } from "node:test";
import { aiPrompt, fence, firstErrorBlock, isErrorLine, maskSecrets } from "../src/log";

test("error lines, not their look-alikes", () => {
  for (const l of ["Error: Cannot find module 'x'", "npm ERR! code 1", "Build failed", "Command \"npm run build\" exited with 1", "Traceback (most recent call last):", "src/a.ts(3,1): error TS2304"])
    assert.ok(isErrorLine(l), l);
  for (const l of ["Compiled ErrorBoundary.tsx", "onError handler set", "Found 0 errors", "warning: deprecated", "Build cache not found", "Done"])
    assert.ok(!isErrorLine(l), l);
});

test("firstErrorBlock: from 10 lines before the first error, 80 at most", () => {
  const lines = Array.from({ length: 200 }, (_, i) => `line ${i}`);
  lines[50] = "Error: first"; lines[120] = "Error: cascade";
  const b = firstErrorBlock(lines.join("\n"));
  assert.equal(b.found, true);
  const out = b.text.split("\n");
  assert.equal(out[0], "line 40"); assert.equal(out[10], "Error: first"); assert.equal(out.length, 80);
});

test("firstErrorBlock: without an error, the last 40 lines; colours gone", () => {
  const log = Array.from({ length: 100 }, (_, i) => `\u001b[32mline ${i}\u001b[0m`).join("\n") + "\n\n";
  const b = firstErrorBlock(log);
  assert.equal(b.found, false);
  assert.equal(b.text.split("\n")[0], "line 60");
  assert.equal(b.text.split("\n").length, 40);
});

test("secrets are masked", () => {
  // Built here, so the repo's public-data check does not see a key-shaped string.
  const t = maskSecrets("GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz12 and " + "rnd" + "_abcdefghijklmnopqrst and https://u:pw@host/x and Authorization: Bearer abcdefghijkl");
  assert.ok(!/ghp_|rnd_abc|:pw@|abcdefghijkl$/.test(t), t);
  assert.match(t, /\[HIDDEN\]/);
});

test("the shapes of the CLI's masker are masked too", () => {
  const k = (a: string, b: string) => a + b; // built here, as above
  const t = maskSecrets([k("glpat-", "abcdefgh1234"), k("sk_live_", "abcdefgh1234"), k("whsec_", "abcdefgh1234"),
    k("AIza", "abcdefghijklmnopqrstuv12"), k("npm_", "abcdefghijklmnopqrst12"), k("ASIA", "ABCDEFGHIJKL1234"),
    k("-----BEGIN RSA PRIVATE ", "KEY-----\nabc\n-----END RSA PRIVATE KEY-----")].join(" "));
  assert.ok(!/glpat-a|sk_live_a|whsec_a|AIzaa|npm_a|ASIAA|\nabc\n/.test(t), t);
});

test("the masking covers what the app, CLI and MCP server mask", () => {
  const cases: [string, string][] = [
    ["push glpat-" + "abcdefgh12345678", "push [GITLAB TOKEN]"],
    ["stripe sk_" + "live_abcdefgh1234", "stripe [STRIPE KEY]"],
    ["stripe rk_" + "live_abcdefgh1234", "stripe [STRIPE KEY]"],
    ["google AIza" + "SyA1234567890abcdefghijk", "google [GOOGLE KEY]"],
    ["npm npm_" + "abcdefghijklmnopqrstuvwx", "npm [NPM TOKEN]"],
    ["claude sk-ant-" + "api03-ABCDEFGHIJKLMNOP", "claude [API KEY]"],
    ["vercel --token abcdef123456 deploy", "vercel --token [HIDDEN] deploy"],
    ["vercel --token=abcdef123456", "vercel --token=[HIDDEN]"],
    ["by dev@example.com", "by [EMAIL]"],
  ];
  for (const [input, want] of cases) assert.equal(maskSecrets(input), want, input);
  const key = "a\n-----BEGIN RSA " + "PRIVATE KEY-----\nMIIE\nabc\n-----END RSA PRIVATE KEY-----\nb";
  assert.equal(maskSecrets(key), "a\n[PRIVATE KEY]\nb");
  // The excerpt may end inside a key: what is left of it goes too.
  assert.equal(maskSecrets("x -----BEGIN " + "PRIVATE KEY-----\nMIIE\nQUJD"), "x [PRIVATE KEY]");
  assert.equal(maskSecrets("QUJDREVGR0hJSktM\n-----END " + "PRIVATE KEY-----\nafter"), "[PRIVATE KEY]\nafter");
});

test("fence outgrows backticks in the log", () => {
  assert.equal(fence("no ticks"), "```");
  assert.equal(fence("a ```` b"), "`````");
});

test("aiPrompt names the project and fences the first error", () => {
  const p = aiPrompt({ name: "web", platform: "vercel", repo: "me/app", state: "ERROR" }, "ok\nError: boom\n");
  assert.match(p, /^The Vercel deploy of "web" failed\. Repo: me\/app\. Status: ERROR\./);
  assert.match(p, /```\nok\nError: boom\n```/);
});
