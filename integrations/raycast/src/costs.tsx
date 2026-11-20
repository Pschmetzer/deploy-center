import { Action, ActionPanel, Color, Icon, List, Keyboard } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { monthCosts } from "./lib/deploys";
import { money, monthSentence, perBuild } from "./lib/insights";
import { ErrorView } from "./lib/ui";

// What Vercel charged this month, by day and by project (`deploys costs 31`). It only reads.
export default function Costs() {
  const { data, error, isLoading, revalidate } = useCachedPromise(monthCosts, [], {
    keepPreviousData: true,
    onError: () => undefined,
  });
  const copy = data ? monthSentence(data) : "";
  const recent = [...(data?.days ?? [])].reverse().slice(0, 14);
  const actions = (
    <ActionPanel>
      {copy ? <Action.CopyToClipboard title="Copy Summary" content={copy} /> : null}
      <Action
        title="Refresh"
        icon={Icon.ArrowClockwise}
        shortcut={Keyboard.Shortcut.Common.Refresh}
        onAction={revalidate}
      />
    </ActionPanel>
  );

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter days and projects">
      {error ? (
        <ErrorView error={error} onRetry={revalidate} />
      ) : (
        <>
          <List.EmptyView
            icon={{ source: Icon.Coins }}
            title={isLoading ? "Reading the charges …" : "No charges"}
            description={
              isLoading ? "Asking Vercel for each day of the month." : "Vercel has no charges for the last 31 days."
            }
          />
          {data ? (
            <List.Section title="This month">
              <List.Item
                icon={Icon.Coins}
                title={data.month ? money(data.month.total) : "–"}
                subtitle={data.month ? data.month.month : "no day of this month read"}
                accessories={[
                  ...(data.month?.build !== null && data.month
                    ? [{ text: `builds ${money(data.month.build ?? 0)}` }]
                    : []),
                  ...(data.missingDays > 0
                    ? [
                        {
                          tag: { value: `${data.missingDays} days missing`, color: Color.Orange },
                          tooltip: "Some days could not be read: the sum is a floor.",
                        },
                      ]
                    : []),
                ]}
                actions={actions}
              />
            </List.Section>
          ) : null}
          <List.Section
            title="Projects, last 7 days"
            subtitle={data?.projects.length ? String(data.projects.length) : undefined}
          >
            {(data?.projects ?? []).map((p) => {
              const one = perBuild(p);
              return (
                <List.Item
                  key={p.name}
                  icon={Icon.Hammer}
                  title={p.name}
                  subtitle={money(p.build)}
                  accessories={[
                    ...(p.builds !== null ? [{ text: `${p.builds} ${p.builds === 1 ? "build" : "builds"}` }] : []),
                    ...(one !== null ? [{ text: `≈ ${money(one)} each` }] : []),
                  ]}
                  actions={actions}
                />
              );
            })}
          </List.Section>
          <List.Section title="Days" subtitle={recent.length ? `last ${recent.length}` : undefined}>
            {recent.map((d) => (
              <List.Item
                key={d.day}
                icon={Icon.Calendar}
                title={d.day}
                subtitle={money(d.total)}
                accessories={[{ text: `builds ${money(d.build)}` }]}
                actions={actions}
              />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}
