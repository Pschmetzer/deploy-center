import { Action, ActionPanel, Color, Icon, List, Keyboard } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useState } from "react";
import { deployCenterURL, journalRows } from "./lib/deploys";
import { isFailedState } from "./lib/text";
import { JournalRow, plain, searchJournal } from "./lib/insights";
import { ErrorView, platformIcon, platformTag } from "./lib/ui";

const DAYS = 90;

function resultColor(result: string): Color {
  if (isFailedState(result)) return Color.Red;
  if (/^(rollback|forced|cancel)/i.test(result)) return Color.Orange;
  return Color.SecondaryText;
}

// Search the journal of the last 90 days: every word must be in the project, platform, result or text.
// It reads `deploys journal export` (a local file) and starts nothing.
export default function JournalSearch() {
  const [query, setQuery] = useState("");
  const { data, error, isLoading, revalidate } = useCachedPromise(journalRows, [DAYS], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const hits = searchJournal(data ?? [], query);
  const row = (r: JournalRow, i: number) => (
    <List.Item
      key={`${r.at}/${r.platform}/${r.name}/${i}`}
      icon={platformIcon(r.platform)}
      title={r.name}
      subtitle={plain(r.detail)}
      accessories={[
        { tag: { value: r.result || "?", color: resultColor(r.result) } },
        platformTag(r.platform),
        { text: r.at.replace("T", " ").slice(0, 16) },
      ]}
      actions={
        <ActionPanel title={r.name}>
          <Action.CopyToClipboard
            title="Copy Line"
            content={`${r.at} ${r.platform}:${r.name} ${r.result} ${plain(r.detail, 400)}`}
          />
          <Action.Open
            title="Show in Deploy Center"
            icon={Icon.AppWindow}
            target={deployCenterURL(`${r.platform}:${r.name}`)}
            shortcut={Keyboard.Shortcut.Common.Open}
          />
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={Keyboard.Shortcut.Common.Refresh}
            onAction={revalidate}
          />
        </ActionPanel>
      }
    />
  );

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      onSearchTextChange={setQuery}
      searchBarPlaceholder="Search the journal: project, platform, result, text"
    >
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.Book }}
            title={isLoading ? "Reading the journal …" : query ? "No entry matches" : "The journal is empty"}
            description={
              query
                ? `Nothing in the last ${DAYS} days has all of: ${query}`
                : `Entries of the last ${DAYS} days show here.`
            }
          />
          <List.Section
            title="Journal"
            subtitle={
              hits.length ? `${hits.length}${hits.length >= 200 ? "+" : ""} of the last ${DAYS} days` : undefined
            }
          >
            {hits.map(row)}
          </List.Section>
        </>
      )}
    </List>
  );
}
