import { Action, ActionPanel, Alert, Color, Icon, List, Toast, confirmAlert, showToast } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useState } from "react";
import { ChangedProject, changed, deploy, platformLabel, plural } from "./lib/deploys";
import { changedItemProps, commitsText, sortByAge } from "./lib/changed";
import { ErrorView, ProjectActions, WarningItem, errorMessage } from "./lib/ui";

type Outcome = { ok: true; detail: string } | { ok: false; detail: string };

// Starts exactly the projects that were shown and confirmed, one after the other.
// deploy-json takes the same start lock as the app, so a second start within a minute is refused.
async function deployAll(list: ChangedProject[], onEach: (key: string, o: Outcome) => void) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Deploying ${plural(list.length, "project")}` });
  let ok = 0;
  const failed: string[] = [];
  for (const [i, p] of list.entries()) {
    toast.message = `${i + 1} of ${list.length}: ${p.name}`;
    try {
      const r = await deploy(p);
      ok++;
      onEach(`${p.platform}/${p.name}`, { ok: true, detail: r.url ?? r.state ?? r.id });
    } catch (e) {
      failed.push(p.name);
      onEach(`${p.platform}/${p.name}`, { ok: false, detail: errorMessage(e) });
    }
  }
  toast.style = failed.length ? Toast.Style.Failure : Toast.Style.Success;
  toast.title = failed.length ? `${ok} started, ${failed.length} did not start` : `${plural(ok, "deploy")} started`;
  toast.message = failed.length ? `Not started: ${failed.join(", ")}` : "Follow them in Deploy Status.";
}

export default function DeployAllChanged() {
  const { data, error, isLoading, revalidate } = usePromise(changed, [], { onError: () => undefined });
  const [outcomes, setOutcomes] = useState<Record<string, Outcome>>({});
  const [running, setRunning] = useState(false);
  const list = sortByAge(data?.data ?? []);
  const commits = list.reduce((n, p) => n + (p.pendingCommits ?? 0), 0);

  async function start() {
    // Read the list again: the window may have been open for a while, and some projects may be
    // live or ignored by now. The alert shows, and the loop deploys, the fresh list only.
    let fresh: ChangedProject[];
    try {
      fresh = sortByAge((await changed()).data ?? []);
    } catch (e) {
      await showToast({ style: Toast.Style.Failure, title: "Could not read what is waiting", message: errorMessage(e) });
      return;
    }
    if (!fresh.length) {
      await showToast({ style: Toast.Style.Success, title: "Nothing is waiting any more" });
      revalidate();
      return;
    }
    const key = (p: ChangedProject) => `${p.platform}/${p.name}`;
    const gone = list.filter((p) => !fresh.some((f) => key(f) === key(p))).map((p) => p.name);
    const lines = fresh.map((p) => `• ${p.name} (${platformLabel(p.platform)}, ${commitsText(p)})`).join("\n");
    const note = gone.length ? `\n\nNo longer waiting, left out: ${gone.join(", ")}` : "";
    const ok = await confirmAlert({
      title: `Deploy ${plural(fresh.length, "project")}?`,
      message: `Each one builds its newest commit to production:\n\n${lines}${note}`,
      icon: { source: "extension-icon.png" },
      primaryAction: { title: `Deploy ${fresh.length}`, style: Alert.ActionStyle.Destructive },
    });
    if (!ok) return;
    setRunning(true);
    setOutcomes({});
    try {
      await deployAll(fresh, (key, o) => setOutcomes((prev) => ({ ...prev, [key]: o })));
    } finally {
      setRunning(false);
    }
  }

  const deployAllAction = list.length > 0 && !running && (
    <Action
      title={`Deploy All ${list.length}`}
      icon={Icon.Upload}
      style={Action.Style.Destructive}
      shortcut={{ modifiers: ["cmd", "shift"], key: "enter" }}
      onAction={start}
    />
  );

  return (
    <List isLoading={isLoading || running} searchBarPlaceholder="Projects that would be deployed">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.CheckCircle }}
            title={isLoading ? "Reading your projects …" : "Nothing waiting"}
            description={isLoading ? "Asking Vercel, Render and GitHub." : "Nothing to deploy: every project is live."}
            actions={
              <ActionPanel>
                <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} />
              </ActionPanel>
            }
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section
            title={list.length ? "Would Deploy" : undefined}
            subtitle={
              list.length
                ? `${plural(list.length, "project")}, ${plural(commits, "commit")} · ↵ to deploy all`
                : undefined
            }
          >
            {list.map((p) => {
              const key = `${p.platform}/${p.name}`;
              const o = outcomes[key];
              const props = changedItemProps(p);
              return (
                <List.Item
                  key={key}
                  {...props}
                  accessories={
                    o
                      ? [
                          {
                            tag: { value: o.ok ? "started" : "not started", color: o.ok ? Color.Green : Color.Red },
                            tooltip: o.detail,
                          },
                          ...props.accessories,
                        ]
                      : props.accessories
                  }
                  actions={
                    <ActionPanel title={p.name}>
                      {/* Enter on a row is not "deploy everything": that is ⌘⇧↵. */}
                      <ProjectActions name={p.name} onRefresh={revalidate} />
                      {o && <Action.CopyToClipboard title="Copy Result" content={o.detail} />}
                      {deployAllAction}
                    </ActionPanel>
                  }
                />
              );
            })}
          </List.Section>
        </>
      )}
    </List>
  );
}
