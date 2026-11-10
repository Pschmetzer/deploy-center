import { Icon, List } from "@raycast/api";
import { ChangedProject, plural } from "./deploys";
import { platformIcon, platformTag } from "./ui";

export function commitsText(p: ChangedProject): string {
  if (p.rewritten) return "branch rewritten";
  if (p.pendingCommits == null) return "? commits";
  return plural(p.pendingCommits, "commit") + (p.pendingPartial ? "+" : "");
}

export function prsText(p: ChangedProject): string | undefined {
  if (p.pendingPRs == null || p.pendingPRs === 0) return undefined;
  return plural(p.pendingPRs, "PR");
}

// "4 commits, 2 PRs waiting, the oldest since 3 days" for alerts and toasts.
export function waitingSentence(p: ChangedProject): string {
  const parts = [commitsText(p), prsText(p)].filter(Boolean).join(", ");
  const age = p.oldestPendingAt ? `, oldest from ${new Date(p.oldestPendingAt * 1000).toLocaleString()}` : "";
  return `${parts} waiting${age}.`;
}

// Oldest first: what has waited longest comes first.
export function sortByAge(list: ChangedProject[]): ChangedProject[] {
  return [...list].sort((a, b) => (a.oldestPendingAt ?? Infinity) - (b.oldestPendingAt ?? Infinity));
}

export function changedAccessories(p: ChangedProject): List.Item.Accessory[] {
  const acc: List.Item.Accessory[] = [{ text: commitsText(p), icon: Icon.Dot, tooltip: "Commits not live yet" }];
  const prs = prsText(p);
  if (prs) acc.push({ text: prs, icon: Icon.Code, tooltip: "Pull requests among them" });
  if (p.oldestPendingAt) {
    const d = new Date(p.oldestPendingAt * 1000);
    acc.push({ date: d, icon: Icon.Clock, tooltip: `Oldest waiting commit: ${d.toLocaleString()}` });
  }
  acc.push(platformTag(p.platform));
  return acc;
}

export function changedItemProps(p: ChangedProject) {
  return {
    icon: platformIcon(p.platform),
    title: p.name,
    subtitle: p.headMsg ?? p.repo ?? undefined,
    keywords: [p.platform, p.repo ?? ""].filter(Boolean),
    accessories: changedAccessories(p),
  };
}
