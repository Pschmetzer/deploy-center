// Which projects belong to the open folder: their repo against the folder's git remotes.

/**
 * "host/full/path", lower case: the host matters, so gitlab.com:me/app is not GitHub's me/app.
 * Remotes in any spelling (git@host:path, https, ssh, scp); the CLI's repos as it writes them: "me/app" is GitHub,
 * "gitlab.com/group/sub/name" names its host first (lib/githost.sh). Null when there is no path.
 */
export function repoKey(remote: string): string | null {
  let s = remote.trim();
  if (!s) return null;
  s = s.replace(/\.git\/?$/i, "").replace(/\/+$/, "");
  let host: string, path: string;
  const scp = /^[^/@:\s]+@([^/:\s]+):(.+)$/.exec(s);
  if (scp) { host = scp[1]; path = scp[2]; }
  else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) {
    try { const u = new URL(s); host = u.hostname; path = u.pathname; } catch { return null; }
  } else {
    const parts = s.split("/").filter(Boolean);
    // A first part with a dot is a host (gitlab.com/group/name); "owner/name" alone is GitHub.
    if (parts.length >= 3 && parts[0].includes(".")) { host = parts[0]; path = parts.slice(1).join("/"); }
    else { host = "github.com"; path = s; }
  }
  const parts = path.split("/").filter(Boolean);
  if (parts.length < 2) return null;
  return `${host.replace(/^www\./i, "")}/${parts.join("/")}`.replace(/\.git$/i, "").toLowerCase();
}

/** "owner/name" of a remote whose host has no dot (an ssh alias such as github-work), else null. */
export function aliasPath(remote: string): string | null {
  const k = repoKey(remote);
  if (!k) return null;
  const i = k.indexOf("/");
  const host = k.slice(0, i);
  return host.includes(".") || host === "localhost" ? null : k.slice(i + 1);
}

/**
 * The remote URLs in `git remote -v` output, once each. A remote named "upstream" is left out
 * (the convention for the project one forked): its projects are not the ones this folder deploys.
 */
export function parseRemotes(gitRemoteV: string): string[] {
  const urls = new Set<string>();
  for (const line of gitRemoteV.split("\n")) {
    const m = /^(\S+)\s+(\S+)/.exec(line.trim());
    if (m && m[1] !== "upstream") urls.add(m[2]);
  }
  return [...urls];
}

export type Scope = "auto" | "repo" | "all";

export interface Scoped<T> {
  projects: T[];
  /** True when the list is the folder's own projects. */
  matched: boolean;
}

/**
 * The folder's projects (repo matches a remote). "auto" falls back to all when none match,
 * "repo" shows none then, "all" never filters.
 */
export function scopeProjects<T extends { repo: string | null }>(projects: T[], remotes: string[], scope: Scope): Scoped<T> {
  if (scope === "all") return { projects, matched: false };
  const keys = new Set(remotes.map(repoKey).filter((s): s is string => !!s));
  // An SSH host alias from ~/.ssh/config (git@github-work:me/app) is no real host: its path is compared with
  // the projects on GitHub, the only host with a short "owner/name".
  const aliasPaths = new Set(remotes.map(aliasPath).filter((s): s is string => !!s));
  const mine = projects.filter((p) => {
    if (p.repo === null) return false;
    const k = repoKey(p.repo) ?? "";
    return keys.has(k) || (k.startsWith("github.com/") && aliasPaths.has(k.slice("github.com/".length)));
  });
  if (mine.length || scope === "repo") return { projects: mine, matched: mine.length > 0 };
  return { projects, matched: false };
}
