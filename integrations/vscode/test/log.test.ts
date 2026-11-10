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

test("fence outgrows backticks in the log", () => {
  assert.equal(fence("no ticks"), "```");
  assert.equal(fence("a ```` b"), "`````");
});

test("aiPrompt names the project and fences the first error", () => {
  const p = aiPrompt({ name: "web", platform: "vercel", repo: "me/app", state: "ERROR" }, "ok\nError: boom\n");
  assert.match(p, /^The Vercel deploy of "web" failed\. Repo: me\/app\. Status: ERROR\./);
  assert.match(p, /```\nok\nError: boom\n```/);
});
