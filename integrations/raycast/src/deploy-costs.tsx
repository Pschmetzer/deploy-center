import { Action, ActionPanel, Icon, List, open } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { deployCenterURL, planDetails, plural } from "./lib/deploys";
import { costText, planRowText } from "./lib/text";
import { ErrorView, WarningItem, platformIcon, platformTag } from "./lib/ui";

// What the next deploy would start and what it would cost, from `deploys plan --json`. An estimate (build
// minutes times a rate), not a bill. It only reads: nothing starts here.
export default function DeployCosts() {
  const { data, error, isLoading, revalidate } = useCachedPromise(planDetails, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const projects = data?.data.projects ?? [];
  const total = data?.data.total ?? null;
  const sum = costText(total);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter projects in the next deploy">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.CheckCircle }}
            title={isLoading ? "Working out the plan …" : "Nothing would start"}
            description={isLoading ? "Asking your hosts and GitHub." : "No project has commits waiting."}
          />
          <WarningItem warning={data?.warning} onRetry={revalidate} />
          <List.Section
            title="Next deploy (estimate)"
            subtitle={
              total
                ? `${plural(total.builds, "build")}${sum ? `, ${sum}` : ""}${total.unpriced ? ` (${total.unpriced} without a price)` : ""}`
                : undefined
            }
          >
            {projects.map((p) => (
              <List.Item
                key={`${p.platform}/${p.name}`}
                icon={platformIcon(p.platform)}
                title={p.name}
                subtitle={planRowText(p)}
                keywords={[p.platform]}
                accessories={[platformTag(p.platform)]}
                actions={
                  <ActionPanel title={p.name}>
                    <Action
                      title="Show in Deploy Center"
                      icon={Icon.AppWindow}
                      onAction={() => open(deployCenterURL(`${p.platform}:${p.name}`))}
                    />
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
