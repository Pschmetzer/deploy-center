import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { changed, plural } from "./lib/deploys";
import { changedItemProps, sortByAge, waitingSentence } from "./lib/changed";
import { ErrorView, ProjectActions, WarningItem, confirmAndDeploy } from "./lib/ui";

export default function WaitingDeploys() {
  const { data, error, isLoading, revalidate } = usePromise(changed, [], {
    // Errors are shown in the list itself, not as an extra toast.
    onError: () => undefined,
  });
  const list = sortByAge(data?.data ?? []);
  const commits = list.reduce((n, p) => n + (p.pendingCommits ?? 0), 0);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter projects with waiting commits">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.CheckCircle }}
            title={isLoading ? "Reading your projects …" : "Nothing waiting"}
            description={isLoading ? "Asking Vercel, Render and GitHub." : "Every project is on its newest commit."}
            actions={
              <ActionPanel>
                <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} />
              </ActionPanel>
            }
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section
            title="Waiting"
            subtitle={list.length ? `${plural(list.length, "project")}, ${plural(commits, "commit")}` : undefined}
          >
            {list.map((p) => (
              <List.Item
                key={`${p.platform}/${p.name}`}
                {...changedItemProps(p)}
                actions={
                  <ActionPanel title={p.name}>
                    <Action
                      title="Deploy"
                      icon={Icon.Upload}
                      onAction={() => confirmAndDeploy(p, waitingSentence(p), revalidate)}
                    />
                    <ProjectActions name={p.name} projectRef={p.projectRef} onRefresh={revalidate} />
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
