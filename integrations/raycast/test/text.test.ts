// Unit tests for the parts of the extension that need no Raycast API (src/lib/text.ts and
// src/lib/log.ts). Run: npm test (tsc into .test-out, then node --test). No network, no Raycast.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import type { ChangedProject } from "../src/lib/deploys";
import { aiPrompt, firstErrorBlock, isErrorLine, maskSecrets } from "../src/lib/log";
import {
  classify,
  commitsText,
  isFailedState,
  lastLines,
  platformLabel,
  plural,
  prsText,
  sortByAge,
  waitingSentence,
} from "../src/lib/text";

const project = (o: Partial<ChangedProject>): ChangedProject =>
  ({ name: "web", platform: "vercel", projectRef: "web", ...o }) as ChangedProject;

test("classify: a login error only from stderr's words, not any 401", () => {
  assert.equal(classify("Error: not logged in. Run vercel login"), "auth");
  assert.equal(classify("HTTP 401 from api.render.com"), "auth");
  assert.equal(classify("Fix #401 in api-403"), "failed");
  assert.equal(classify("something broke"), "failed");
});

test("lastLines: colour codes out, empty lines out, the last n", () => {
  assert.equal(lastLines("\u001b[31ma\u001b[0m\n\nb\nc\nd", 3), "b\nc\nd");
});

test("commitsText and prsText", () => {
  assert.equal(commitsText(project({ pendingCommits: 1 })), "1 commit");
  assert.equal(commitsText(project({ pendingCommits: 4, pendingPartial: true })), "4 commits+");
  assert.equal(commitsText(project({ pendingCommits: null })), "? commits");
  assert.equal(commitsText(project({ rewritten: true, pendingCommits: 3 })), "branch rewritten");
  assert.equal(prsText(project({ pendingPRs: 0 })), undefined);
  assert.equal(prsText(project({ pendingPRs: 2 })), "2 PRs");
});

test("waitingSentence names commits and PRs", () => {
  assert.equal(waitingSentence(project({ pendingCommits: 2, pendingPRs: 1 })), "2 commits, 1 PR waiting.");
});

test("sortByAge: oldest first, unknown age last, input untouched", () => {
  const list = [
    project({ name: "new", oldestPendingAt: 300 }),
    project({ name: "unknown" }),
    project({ name: "old", oldestPendingAt: 100 }),
  ];
  assert.deepEqual(
    sortByAge(list).map((p) => p.name),
    ["old", "new", "unknown"],
  );
  assert.equal(list[0].name, "new");
});

test("labels and counts", () => {
  assert.equal(platformLabel("amplify"), "AWS Amplify");
  assert.equal(platformLabel("fly"), "Fly");
  assert.equal(plural(1, "project"), "1 project");
  assert.equal(plural(0, "project"), "0 projects");
  assert.equal(isFailedState("ERROR"), true);
  assert.equal(isFailedState("build_failed"), true);
  assert.equal(isFailedState("READY"), false);
  assert.equal(isFailedState(null), false);
});

test("maskSecrets: the tokens the MCP server and VS Code mask", () => {
  const log = [
    "VERCEL_TOKEN=s3cr3t-value npm run build",
    "pushing with ghp_abcdefghijklmnop1234 and glpat-abcdefgh12345",
    "stripe sk_live_abcdefgh1234, aws AKIAABCDEFGHIJKLMNOP, mail dev@example.com",
    "DATABASE_URL=postgres://admin:dbpass@db.internal:5432/app",
    "-----BEGIN PRIVATE KEY-----",
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC",
    "-----END PRIVATE KEY-----",
  ].join("\n");
  const out = maskSecrets(log);
  for (const leaked of [
    "s3cr3t-value",
    "ghp_abcdefghijklmnop1234",
    "glpat-abcdefgh12345",
    "sk_live_abcdefgh1234",
    "AKIAABCDEFGHIJKLMNOP",
    "dev@example.com",
    "dbpass",
    "MIIEvQIBADANBg",
  ]) {
    assert.ok(!out.includes(leaked), `${leaked} is still in: ${out}`);
  }
  assert.ok(out.includes("VERCEL_TOKEN=[HIDDEN]"), out);
  assert.ok(out.includes("[PRIVATE KEY]"), out);
});

test("firstErrorBlock and aiPrompt: from the first real error, masked, fenced", () => {
  assert.equal(isErrorLine("compiled ErrorBoundary.tsx"), false);
  assert.equal(isErrorLine("0 errors"), false);
  assert.equal(isErrorLine("Error: Cannot find module 'x'"), true);
  const log = ["install", "build", "Error: Cannot find module 'x' (token=abc12345)", "at y"].join("\n");
  const b = firstErrorBlock(log);
  assert.equal(b.found, true);
  assert.ok(b.text.startsWith("install"));
  assert.ok(!b.text.includes("abc12345"));
  const prompt = aiPrompt({ name: "web", platform: "vercel", repo: null, state: "ERROR" }, "a ``` b\nError: x");
  assert.ok(prompt.startsWith('The Vercel deploy of "web" failed. Status: ERROR.'), prompt);
  assert.ok(prompt.includes("````\n"), "the fence is longer than the backticks in the log");
});

// The fixture the CLI, the iPhone app and the MCP server are checked against
// (ios/Tests/fixtures/mask-in.txt): every secret in it carries the word SECRET, and none may
// survive. Labels like [WEBHOOK SECRET] and the name SECRET_KEY= do not count.
test("no secret of the shared fixture survives", () => {
  const input = readFileSync(join(__dirname, "../../../..", "ios", "Tests", "fixtures", "mask-in.txt"), "utf8");
  const left = maskSecrets(input)
    .split("\n")
    .filter((l) =>
      l
        .replace(/\[[A-Z ]+\]/g, "")
        .replace(/SECRET_KEY=/g, "")
        .includes("SECRET"),
    );
  assert.deepEqual(left, []);
});
