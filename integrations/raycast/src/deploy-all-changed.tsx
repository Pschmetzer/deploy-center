import { Action, ActionPanel, Alert, Color, Icon, List, LocalStorage, Toast, confirmAlert, showToast } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect, useState } from "react";
import { ChangedProject, changed, deploy, platformLabel, plural } from "./lib/deploys";
import { changedItemProps, commitsText, sortByAge } from "./lib/changed";
import { ErrorView, ProjectActions, WarningItem, errorMessage } from "./lib/ui";

type Outcome = { ok: true; detail: string } | { ok: false; detail: string };

// A run in progress, kept in LocalStorage: if Raycast is closed in the middle, the next open says
// which projects were never reached. Removed when the run ends.
const RUN_KEY = "deploy-all-run";
interface Run {
  at: number; // ms
  names: string[]; // platform/name, in order
  reached: string[]; // the ones whose start was tried
}
async function saveRun(r: Run | null) {
  if (r) await LocalStorage.setItem(RUN_KEY, JSON.stringify(r));
  else await LocalStorage.removeItem(RUN_KEY);
}
async function loadRun(): Promise<Run | null> {
  const raw = await LocalStorage.getItem<string>(RUN_KEY);
  if (!raw) return null;
  try {
    const r = JSON.parse(raw) as Run;
    return Array.isArray(r.names) && Array.isArray(r.reached) ? r : null;
  } catch {
    return null;
  }
}

// Starts exactly the projects that were shown and confirmed, one after the other.
// deploy-json takes the same start lock as the app, so a second start within a minute is refused.
async function deployAll(list: ChangedProject[], onEach: (key: string, o: Outcome) => void) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Deploying ${plural(list.length, "project")}` });
  let ok = 0;
  const failed: string[] = [];
  const run: Run = { at: Date.now(), names: list.map((p) => `${p.platform}/${p.name}`), reached: [] };
  await saveRun(run);
  for (const [i, p] of list.entries()) {
    toast.message = `${i + 1} of ${list.length}: ${p.name}`;
    run.reached.push(`${p.platform}/${p.name}`);
    await saveRun(run);
    try {
      const r = await deploy(p);
      ok++;
      onEach(`${p.platform}/${p.name}`, { ok: true, detail: r.url ?? r.state ?? r.id });
    } catch (e) {
      failed.push(p.name);
      onEach(`${p.platform}/${p.name}`, { ok: false, detail: errorMessage(e) });
    }
  }
  await saveRun(null);
  toast.style = failed.length ? Toast.Style.Failure : Toast.Style.Success;
  toast.title = failed.length ? `${ok} started, ${failed.length} did not start` : `${plural(ok, "deploy")} started`;
  toast.message = failed.length ? `Not started: ${failed.join(", ")}` : "Follow them in Deploy Status.";
}

export default function DeployAllChanged() {
  const { data, error, isLoading, revalidate } = useCachedPromise(changed, [], { onError: () => undefined });
  const [outcomes, setOutcomes] = useState<Record<string, Outcome>>({});
  const [running, setRunning] = useState(false);
  const [stopped, setStopped] = useState<Run | null>(null);
  useEffect(() => {
    // Only when no run of this window is going on: an unfinished run of an earlier one.
    loadRun().then((r) => {
      if (r && r.reached.length < r.names.length) setStopped(r);
      else if (r) void saveRun(null);
    });
  }, []);
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
    setStopped(null);
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
          {stopped && !running && (
            <List.Item
              icon={{ source: Icon.ExclamationMark, tintColor: Color.Orange }}
              title="An earlier Deploy All stopped early"
              subtitle={`${stopped.reached.length} of ${stopped.names.length} reached, ${new Date(stopped.at).toLocaleString()}. Never started: ${stopped.names
                .filter((n) => !stopped.reached.includes(n))
                .map((n) => n.split("/").slice(1).join("/"))
                .join(", ")}`}
              actions={
                <ActionPanel>
                  {deployAllAction}
                  <Action
                    title="Dismiss"
                    icon={Icon.XMarkCircle}
                    onAction={() => {
                      setStopped(null);
                      void saveRun(null);
                    }}
                  />
                </ActionPanel>
              }
            />
          )}
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
