import { Action, ActionPanel, Clipboard, Color, Detail, Icon, List, Toast, showToast } from "@raycast/api";
import { useCachedPromise, usePromise } from "@raycast/utils";
import { StatusProject, buildLog, isFailedState, platformLabel, status } from "./lib/deploys";
import { aiPrompt, fence, maskSecrets } from "./lib/log";
import { ErrorView, ProjectActions, WarningItem, errorMessage, platformTag } from "./lib/ui";

// The newest build log, masked, in a Detail view (what VS Code's "Show log" opens).
function LogView(props: { p: StatusProject }) {
  const { p } = props;
  const { data, error, isLoading } = usePromise(buildLog, [p.projectRef], { onError: () => undefined });
  const log = data === undefined ? "" : maskSecrets(data);
  const f = fence(log);
  const markdown = error
    ? `**Could not read the log of ${p.name}.**\n\n${errorMessage(error)}`
    : isLoading
      ? "Reading the build log …"
      : `${f}\n${log || "(empty)"}\n${f}`;
  return (
    <Detail
      isLoading={isLoading}
      navigationTitle={`${p.name} · build log`}
      markdown={markdown}
      actions={
        <ActionPanel>
          {log ? <Action title="Copy for AI" icon={Icon.Wand} onAction={() => copyForAi(p, data)} /> : null}
          {log ? <Action.CopyToClipboard title="Copy Log" content={log} /> : null}
        </ActionPanel>
      }
    />
  );
}

// The first error block with a short prompt, ready for Claude Code, Cursor or a chat. Masked.
async function copyForAi(p: StatusProject, log?: string) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Reading the build log of ${p.name}` });
  try {
    const text = log ?? (await buildLog(p.projectRef));
    await Clipboard.copy(aiPrompt({ name: p.name, platform: p.platform, repo: null, state: p.state }, text));
    toast.style = Toast.Style.Success;
    toast.title = "Copied the first error";
    toast.message = "Ready to paste into Claude Code, Cursor or a chat";
  } catch (e) {
    toast.style = Toast.Style.Failure;
    toast.title = `Could not read the log of ${p.name}`;
    toast.message = errorMessage(e);
  }
}

function StatusItem(props: { p: StatusProject; onRefresh: () => void }) {
  const { p } = props;
  const building = p.building;
  return (
    <List.Item
      icon={
        building
          ? { source: Icon.CircleProgress50, tintColor: Color.Blue }
          : { source: Icon.XMarkCircle, tintColor: Color.Red }
      }
      title={p.name}
      subtitle={building ? "Building" : "Newest deploy failed"}
      keywords={[p.platform]}
      accessories={[
        ...(p.state ? [{ tag: { value: p.state, color: building ? Color.Blue : Color.Red }, tooltip: "State" }] : []),
        ...(p.changed ? [{ icon: Icon.Dot, text: "changes waiting" }] : []),
        platformTag(p.platform),
      ]}
      actions={
        <ActionPanel title={`${p.name} (${platformLabel(p.platform)})`}>
          {building ? null : (
            <ActionPanel.Section>
              <Action.Push title="Show Log" icon={Icon.Terminal} target={<LogView p={p} />} />
              <Action title="Copy for AI" icon={Icon.Wand} onAction={() => copyForAi(p)} />
            </ActionPanel.Section>
          )}
          <ProjectActions name={p.name} projectRef={p.projectRef} onRefresh={props.onRefresh} />
        </ActionPanel>
      }
    />
  );
}

export default function DeployStatus() {
  // The last list shows at once and is read again in the background (a read can take a minute).
  const { data, error, isLoading, revalidate } = useCachedPromise(status, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const all = data?.data ?? [];
  const building = all.filter((p) => p.building);
  const failed = all.filter((p) => !p.building && isFailedState(p.state));

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter building and failed projects">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.CheckCircle }}
            title={isLoading ? "Reading your projects …" : "Nothing building, nothing failed"}
            description={
              isLoading ? "Asking Vercel, Render and GitHub." : `${all.length} projects, all quiet. Refresh with ⌘R.`
            }
            actions={
              <ActionPanel>
                <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} />
              </ActionPanel>
            }
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section title="Building" subtitle={building.length ? String(building.length) : undefined}>
            {building.map((p) => (
              <StatusItem key={`${p.platform}/${p.name}`} p={p} onRefresh={revalidate} />
            ))}
          </List.Section>
          <List.Section title="Failed" subtitle={failed.length ? String(failed.length) : undefined}>
            {failed.map((p) => (
              <StatusItem key={`${p.platform}/${p.name}`} p={p} onRefresh={revalidate} />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}
