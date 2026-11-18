import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { idleProjects, plural } from "./lib/deploys";
import { idleText } from "./lib/text";
import { ErrorView, WarningItem, platformIcon, platformTag } from "./lib/ui";

// Projects nobody has deployed for 90 days: candidates to pause. It only reads; pausing is yours to do.
export default function IdleProjects() {
  const { data, error, isLoading, revalidate } = useCachedPromise(idleProjects, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const list = data?.data ?? [];

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter idle projects">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.CheckCircle }}
            title={isLoading ? "Reading your projects …" : "No idle projects"}
            description={isLoading ? "Asking your hosts." : "Every project was deployed in the last 90 days."}
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section
            title="Idle for 90 days or more"
            subtitle={list.length ? plural(list.length, "project") : undefined}
          >
            {list.map((p) => (
              <List.Item
                key={`${p.platform}/${p.name}`}
                icon={platformIcon(p.platform)}
                title={p.name}
                subtitle={idleText(p.days)}
                keywords={[p.platform]}
                accessories={[platformTag(p.platform)]}
                actions={
                  <ActionPanel title={p.name}>
                    <Action.CopyToClipboard title="Copy Name" content={p.name} />
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
