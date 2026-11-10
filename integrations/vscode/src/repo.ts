// Which projects belong to the open folder: their repo against the folder's git remotes.

/**
 * "owner/name", lower case, from any spelling of a git remote: git@github.com:me/app.git,
 * https://github.com/me/app, ssh://git@github.com/me/app.git, https://user@github.com/Me/App/.
 * Also takes the CLI's own "me/app" and "https://github.com/me/app". Null when there is no path.
 */
export function repoSlug(remote: string): string | null {
  let s = remote.trim();
  if (!s) return null;
  s = s.replace(/\.git\/?$/i, "").replace(/\/+$/, "");
  let path: string;
  const scp = /^[^/@:\s]+@[^/:\s]+:(.+)$/.exec(s); // git@host:owner/name
  if (scp) path = scp[1];
  else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) {
    try { path = new URL(s).pathname; } catch { return null; }
  } else path = s;
  const parts = path.split("/").filter(Boolean);
  if (parts.length < 2) return null;
  // GitLab subgroups have more than two parts; the CLI only knows GitHub's owner/name.
  return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`.replace(/\.git$/i, "").toLowerCase();
}

/**
 * "host/full/path", lower case: the host matters, so gitlab.com:me/app is not GitHub's me/app.
 * Remotes in any spelling (as repoSlug); the CLI's repos as it writes them: "me/app" is GitHub,
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

/** The remote URLs in `git remote -v` output, once each. */
export function parseRemotes(gitRemoteV: string): string[] {
  const urls = new Set<string>();
  for (const line of gitRemoteV.split("\n")) {
    const m = /^\S+\s+(\S+)/.exec(line.trim());
    if (m) urls.add(m[1]);
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
  const mine = projects.filter((p) => p.repo !== null && keys.has(repoKey(p.repo) ?? ""));
  if (mine.length || scope === "repo") return { projects: mine, matched: mine.length > 0 };
  return { projects, matched: false };
}
