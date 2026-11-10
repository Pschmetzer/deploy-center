import assert from "node:assert/strict";
import { test } from "node:test";
import { parseRemotes, repoSlug, scopeProjects } from "../src/repo";

test("repoSlug reads every spelling of a remote", () => {
  for (const r of [
    "git@github.com:me/app.git", "git@github.com:me/app", "https://github.com/me/app", "https://github.com/me/app.git",
    "https://github.com/Me/App/", "ssh://git@github.com/me/app.git", "https://user:tok@github.com/me/app.git",
    "git://github.com/me/app", "me/app", "Me/App", "  me/app.git\n", "ssh://git@github.com:22/me/app.git",
  ]) assert.equal(repoSlug(r), "me/app", r);
  assert.equal(repoSlug("https://gitlab.com/group/sub/app.git"), "sub/app");
  assert.equal(repoSlug(""), null);
  assert.equal(repoSlug("app"), null);
  assert.equal(repoSlug("https://github.com/"), null);
});

test("parseRemotes: each URL once", () => {
  const out = "origin\tgit@github.com:me/app.git (fetch)\norigin\tgit@github.com:me/app.git (push)\nfork\thttps://github.com/you/app (fetch)\n\n";
  assert.deepEqual(parseRemotes(out), ["git@github.com:me/app.git", "https://github.com/you/app"]);
  assert.deepEqual(parseRemotes(""), []);
});

const ps = [{ name: "a", repo: "me/app" }, { name: "b", repo: "Me/App" }, { name: "c", repo: "me/blog" }, { name: "d", repo: null }];

test("scope auto: the folder's projects, else all", () => {
  assert.deepEqual(scopeProjects(ps, ["git@github.com:me/app.git"], "auto"), { projects: [ps[0], ps[1]], matched: true });
  assert.deepEqual(scopeProjects(ps, ["git@github.com:me/other.git"], "auto"), { projects: ps, matched: false });
  assert.deepEqual(scopeProjects(ps, [], "auto"), { projects: ps, matched: false });
});

test("scope repo shows none without a match; all never filters", () => {
  assert.deepEqual(scopeProjects(ps, ["https://github.com/me/other"], "repo"), { projects: [], matched: false });
  assert.deepEqual(scopeProjects(ps, ["https://github.com/me/blog"], "repo"), { projects: [ps[2]], matched: true });
  assert.deepEqual(scopeProjects(ps, ["https://github.com/me/blog"], "all"), { projects: ps, matched: false });
});

test("a repo is not matched by prefix", () => {
  assert.deepEqual(scopeProjects([{ repo: "me/app-old" }], ["git@github.com:me/app.git"], "repo").projects, []);
});
