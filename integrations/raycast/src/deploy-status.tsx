import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { StatusProject, isFailedState, platformLabel, status } from "./lib/deploys";
import { ErrorView, ProjectActions, WarningItem, platformTag } from "./lib/ui";

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
          <ProjectActions name={p.name} onRefresh={props.onRefresh} />
        </ActionPanel>
      }
    />
  );
}

export default function DeployStatus() {
  const { data, error, isLoading, revalidate } = usePromise(status, [], { onError: () => undefined });
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
