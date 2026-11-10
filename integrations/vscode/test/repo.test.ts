import assert from "node:assert/strict";
import { test } from "node:test";
import { parseRemotes, repoSlug, scopeProjects } from "../src/repo";

test("repoSlug reads every spelling of a remote", () => {
  for (const r of [
    "git@github.com:me/app.git", "git@github.com:me/app", "https://github.com/me/app", "https://github.com/me/app.git",
    "https://github.com/Me/App/", "ssh://git@github.com/me/app.git", "https://user:tok@github.com/me/app.git",
    "git://github.com/me/app", "me/app", "Me/App", "  me/app.git\n", "ssh://git@github.com:22/me/app.git",
  ]) assert.equal(repoSlug(r), "me/app", r);
  // GitLab keeps its host and every subgroup, as the CLI writes it.
  for (const r of ["https://gitlab.com/group/sub/app.git", "git@gitlab.com:group/sub/app.git", "ssh://git@gitlab.com/Group/Sub/App",
    "gitlab.com/group/sub/app"]) assert.equal(repoSlug(r), "gitlab.com/group/sub/app", r);
  assert.equal(repoSlug("github.com/me/app"), "me/app");
  assert.equal(repoSlug("https://git.example.test/me/app"), "git.example.test/me/app");
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

test("the same owner/name on GitHub and GitLab are two repos", () => {
  const both = [{ name: "gh", repo: "me/app" }, { name: "gl", repo: "gitlab.com/me/app" }, { name: "deep", repo: "gitlab.com/x/me/app" }];
  assert.deepEqual(scopeProjects(both, ["git@github.com:me/app.git"], "repo").projects.map((p) => p.name), ["gh"]);
  assert.deepEqual(scopeProjects(both, ["git@gitlab.com:me/app.git"], "repo").projects.map((p) => p.name), ["gl"]);
  assert.deepEqual(scopeProjects(both, ["https://gitlab.com/x/me/app.git"], "repo").projects.map((p) => p.name), ["deep"]);
});

test("a repo is not matched by prefix", () => {
  assert.deepEqual(scopeProjects([{ repo: "me/app-old" }], ["git@github.com:me/app.git"], "repo").projects, []);
});
