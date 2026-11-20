import { Action, ActionPanel, Color, Icon, List, Keyboard } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { freezeStatus, guardStatus } from "./lib/deploys";
import { agoText, freezeText, guardSummary, leftText, plain, ruleText } from "./lib/insights";
import { ErrorView } from "./lib/ui";

// Is the guard on, what did it do last, which allowances are running, and are deploys closed now (the deploy
// freeze). It only reads: `deploys guard status` and `deploys freeze`, never `deploys guard`.
export default function GuardStatus() {
  const guard = useCachedPromise(guardStatus, [], { keepPreviousData: true, onError: () => undefined });
  // The freeze is a second, local read: a failing one never hides the guard.
  const freeze = useCachedPromise(freezeStatus, [], { keepPreviousData: true, onError: () => undefined });
  const g = guard.data;
  const f = freeze.data;
  const now = Math.floor(Date.now() / 1000);
  const refresh = () => {
    guard.revalidate();
    freeze.revalidate();
  };
  const actions = (
    <ActionPanel>
      <Action
        title="Refresh"
        icon={Icon.ArrowClockwise}
        shortcut={Keyboard.Shortcut.Common.Refresh}
        onAction={refresh}
      />
    </ActionPanel>
  );

  return (
    <List isLoading={guard.isLoading || freeze.isLoading} searchBarPlaceholder="Filter">
      {guard.error ? (
        <ErrorView error={guard.error} onRetry={refresh} />
      ) : (
        <>
          <List.Section title="Guard">
            {g ? (
              <List.Item
                icon={{
                  source: g.enabled ? Icon.CheckCircle : Icon.Circle,
                  tintColor: g.enabled ? Color.Green : Color.SecondaryText,
                }}
                title={g.enabled ? "Guard is on" : "Guard is off"}
                subtitle={guardSummary(g, now)}
                actions={actions}
              />
            ) : null}
            {g?.pathMissing.length ? (
              <List.Item
                icon={{ source: Icon.Warning, tintColor: Color.Orange }}
                title="The scheduled job cannot find a tool"
                subtitle={`${g.pathMissing.join(", ")} not on its PATH. In a terminal: deploys guard schedule on`}
                actions={actions}
              />
            ) : null}
            {g?.firstRunPending ? (
              <List.Item
                icon={Icon.Info}
                title="The first run only reports"
                subtitle="It changes nothing before you have seen what it would do."
                actions={actions}
              />
            ) : null}
          </List.Section>
          <List.Section title="Last actions" subtitle={g?.lastRun ? agoText(g.lastRun, now) : undefined}>
            {(g?.actions ?? []).map((a, i) => (
              <List.Item
                key={`a/${i}`}
                icon={a.error ? { source: Icon.XMarkCircle, tintColor: Color.Red } : Icon.Dot}
                title={`${a.action}${a.project ? ` ${a.project}` : ""}`}
                subtitle={a.error ? plain(a.error) : a.platform}
                actions={actions}
              />
            ))}
          </List.Section>
          <List.Section title="Allowances" subtitle={g?.allowances.length ? String(g.allowances.length) : undefined}>
            {(g?.allowances ?? []).map((a) => (
              <List.Item
                key={`w/${a.platform}/${a.project}`}
                icon={Icon.Clock}
                title={a.project}
                subtitle={a.platform}
                accessories={[{ text: leftText(a.expiresAt, now) }]}
                actions={actions}
              />
            ))}
          </List.Section>
          <List.Section title="Deploy freeze">
            <List.Item
              icon={{
                source: f?.closedNow ? Icon.Lock : Icon.LockUnlocked,
                tintColor: f?.closedNow ? Color.Orange : Color.SecondaryText,
              }}
              title={freezeText(f ?? null)}
              subtitle={f?.configured && f.closedNow ? "A deploy needs --force with a reason." : undefined}
              actions={actions}
            />
            {(f?.rules ?? []).map((r) => (
              <List.Item
                key={`r/${r.n}`}
                icon={Icon.Calendar}
                title={ruleText(r)}
                subtitle={`rule ${r.n}`}
                actions={actions}
              />
            ))}
          </List.Section>
        </>
      )}
    </List>
  );
}
