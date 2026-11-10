import { Icon, List } from "@raycast/api";
import { ChangedProject } from "./deploys";
import { commitsText, prsText } from "./text";
import { platformIcon, platformTag } from "./ui";

export { commitsText, prsText, sortByAge, waitingSentence } from "./text";

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
