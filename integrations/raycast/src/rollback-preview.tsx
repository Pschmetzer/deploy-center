import { Action, ActionPanel, Icon, List, open, useNavigation } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { deployCenterURL, history, plural, status } from "./lib/deploys";
import { historyLine, rollbackPreview } from "./lib/text";
import { ErrorView, WarningItem, platformIcon, platformTag } from "./lib/ui";

// Pick a project, see what a rollback would do: the deploy that is current and the one production would go
// back to. It only reads (`deploys history`). The rollback itself is done in Deploy Center, which asks first.
export default function RollbackPreview() {
  const { data, error, isLoading, revalidate } = useCachedPromise(status, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const list = data?.data ?? [];
  const { push } = useNavigation();

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Pick a project to preview its rollback">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.Tray }}
            title={isLoading ? "Reading your projects …" : "No projects"}
            description={isLoading ? "Asking your hosts." : "No project is set up in Deploy Center."}
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section title="Projects" subtitle={list.length ? plural(list.length, "project") : undefined}>
            {list.map((p) => (
              <List.Item
                key={`${p.platform}/${p.name}`}
                icon={platformIcon(p.platform)}
                title={p.name}
                keywords={[p.platform]}
                accessories={[platformTag(p.platform)]}
                actions={
                  <ActionPanel title={p.name}>
                    <Action
                      title="Preview Rollback"
                      icon={Icon.ArrowLeft}
                      onAction={() => push(<Preview name={p.name} projectRef={p.projectRef} />)}
                    />
                    <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} />
                  </ActionPanel>
                }
              />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}

function Preview(props: { name: string; projectRef: string }) {
  const { data, error, isLoading, revalidate } = useCachedPromise(history, [props.projectRef], {
    onError: () => undefined,
  });
  const recent = data?.data ?? [];
  const { current, target } = rollbackPreview(recent);
  const show = (
    <Action
      title="Show in Deploy Center"
      icon={Icon.AppWindow}
      onAction={() => open(deployCenterURL(props.projectRef))}
    />
  );

  return (
    <List isLoading={isLoading} navigationTitle={`Rollback preview: ${props.name}`}>
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView icon={{ source: Icon.Tray }} title="No deploys to show" />
          {current && (
            <List.Section title="Now">
              <List.Item icon={Icon.Dot} title={historyLine(current)} actions={<ActionPanel>{show}</ActionPanel>} />
            </List.Section>
          )}
          <List.Section title="A rollback would go back to" subtitle="nothing is rolled back here">
            {target ? (
              <List.Item
                icon={Icon.ArrowLeft}
                title={historyLine(target)}
                actions={<ActionPanel>{show}</ActionPanel>}
              />
            ) : (
              <List.Item
                icon={Icon.XMarkCircle}
                title="No earlier deploy that went live in the newest five"
                actions={<ActionPanel>{show}</ActionPanel>}
              />
            )}
          </List.Section>
          <List.Section title="Newest deploys">
            {recent.map((d, i) => (
              <List.Item
                key={`${i}-${d.commit ?? d.when ?? ""}`}
                title={historyLine(d)}
                actions={<ActionPanel>{show}</ActionPanel>}
              />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}
