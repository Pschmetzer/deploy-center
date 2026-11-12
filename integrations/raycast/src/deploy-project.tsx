import { LaunchProps, Toast, showToast } from "@raycast/api";
import { changed, platformLabel, status } from "./lib/deploys";
import { waitingSentence } from "./lib/changed";
import { confirmAndDeploy, errorMessage } from "./lib/ui";

// "Deploy <project>": one project by name, from the root search. A name on two platforms is
// written platform:name. Always asks first, like every deploy in this extension.
export default async function DeployProject(props: LaunchProps<{ arguments: { project: string } }>) {
  const want = props.arguments.project.trim();
  const [plat, name] = want.includes(":")
    ? [want.slice(0, want.indexOf(":")), want.slice(want.indexOf(":") + 1)]
    : [null, want];
  try {
    const { data: waiting } = await changed();
    const hits = (waiting ?? []).filter((p) => p.name === name && (!plat || p.platform === plat));
    if (hits.length === 1) return confirmAndDeploy(hits[0], waitingSentence(hits[0]));
    if (hits.length > 1)
      return ambiguous(
        name,
        hits.map((p) => p.platform),
      );
    // Not waiting: still deployable (the newest commit again), if the project exists.
    const { data: all } = await status();
    const known = (all ?? []).filter((p) => p.name === name && (!plat || p.platform === plat));
    if (known.length > 1)
      return ambiguous(
        name,
        known.map((p) => p.platform),
      );
    if (!known.length) {
      await showToast({
        style: Toast.Style.Failure,
        title: `No project called ${want}`,
        message: "Names as in Waiting Deploys or Deploy Status",
      });
      return;
    }
    return confirmAndDeploy(
      known[0],
      `Nothing is known to be waiting on ${platformLabel(known[0].platform)}; this deploys the newest commit again.`,
    );
  } catch (e) {
    await showToast({ style: Toast.Style.Failure, title: "Could not read the projects", message: errorMessage(e) });
  }
}

async function ambiguous(name: string, platforms: string[]) {
  await showToast({
    style: Toast.Style.Failure,
    title: `${name} is on ${platforms.map(platformLabel).join(" and ")}`,
    message: `Write it as ${platforms.map((p) => `${p}:${name}`).join(" or ")}`,
  });
}
