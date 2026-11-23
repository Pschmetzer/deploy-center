import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { deployCenterURL, timelineEntries } from "./lib/deploys";
import { isFailedState } from "./lib/text";
import { TimelineEntry } from "./lib/insights";
import { ErrorView, platformIcon, platformTag } from "./lib/ui";

const DAYS = 7;

function kindColor(kind: string): Color {
  if (isFailedState(kind)) return Color.Red;
  if (/^(rollback|forced|cancel)/i.test(kind)) return Color.Orange;
  return Color.SecondaryText;
}

// What happened in the last 7 days, newest day first, from `deploys timeline --json` (a local file).
// It only reads: nothing starts, rolls back or runs from here.
export default function Timeline() {
  const { data, error, isLoading, revalidate } = useCachedPromise(timelineEntries, [DAYS], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const days = new Map<string, TimelineEntry[]>();
  for (const e of data ?? []) {
    const d = e.at.slice(0, 10);
    days.set(d, [...(days.get(d) ?? []), e]);
  }
  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter the timeline">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.Clock }}
            title={isLoading ? "Reading the journal …" : "Nothing happened"}
            description={isLoading ? "A local file." : `No deploys in the last ${DAYS} days.`}
          />
          {[...days].map(([day, entries]) => (
            <List.Section key={day} title={day} subtitle={`${entries.length}`}>
              {entries.map((e, i) => (
                <List.Item
                  key={`${e.at}/${e.platform}/${e.name}/${i}`}
                  icon={platformIcon(e.platform)}
                  title={e.name}
                  subtitle={e.detail}
                  keywords={[e.kind, e.platform]}
                  accessories={[
                    { tag: { value: e.kind, color: kindColor(e.kind) } },
                    platformTag(e.platform),
                    { text: e.at.replace("T", " ").slice(11, 16) },
                  ]}
                  actions={
                    <ActionPanel title={e.name}>
                      <Action.OpenInBrowser title="Show in Deploy Center" url={deployCenterURL(e.name)} />
                      <Action.CopyToClipboard
                        title="Copy Line"
                        content={`${e.at} ${e.platform}:${e.name} ${e.kind} ${e.detail}`.trim()}
                      />
                      <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={revalidate} />
                    </ActionPanel>
                  }
                />
              ))}
            </List.Section>
          ))}
        </>
      )}
    </List>
  );
}
