import { Color, Icon, Keyboard, LaunchType, MenuBarExtra, launchCommand } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { freezeStatus, guardStatus, monthCosts } from "./lib/deploys";
import { agoText, freezeText, guardSummary, monthSentence, monthTitle } from "./lib/insights";
import { errorMessage } from "./lib/ui";

// The menu bar: this month's Vercel charges, whether deploys are closed (deploy freeze) and the guard. One read
// every 30 minutes (package.json: interval); nothing deploys, rolls back or runs the guard from here.
export default function CostsMenuBar() {
  const costs = useCachedPromise(monthCosts, [], { onError: () => undefined });
  const freeze = useCachedPromise(freezeStatus, [], { onError: () => undefined });
  const guard = useCachedPromise(guardStatus, [], { onError: () => undefined });
  const closed = freeze.data?.closedNow === true;
  // Text as well as colour: "$12.35" and a lock for a closed window.
  const title = [monthTitle(costs.data ?? null), closed ? "🔒" : ""].filter(Boolean).join(" ") || undefined;
  const now = Math.floor(Date.now() / 1000);
  const go = (name: string) => () => launchCommand({ name, type: LaunchType.UserInitiated });
  const refresh = () => {
    costs.revalidate();
    freeze.revalidate();
    guard.revalidate();
  };

  return (
    <MenuBarExtra
      icon={{ source: closed ? Icon.Lock : Icon.Coins, tintColor: closed ? Color.Orange : Color.PrimaryText }}
      title={title}
      isLoading={costs.isLoading || freeze.isLoading || guard.isLoading}
      tooltip={
        costs.data ? `Deploy Center: ${monthSentence(costs.data)}` : "Deploy Center: costs, deploy freeze and guard"
      }
    >
      <MenuBarExtra.Section title="This month">
        {costs.error ? (
          <MenuBarExtra.Item title={errorMessage(costs.error)} icon={Icon.Warning} />
        ) : (
          <MenuBarExtra.Item
            title={costs.data ? monthSentence(costs.data) : "Reading the charges …"}
            icon={Icon.Coins}
            onAction={go("costs")}
          />
        )}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section title="Deploy freeze">
        <MenuBarExtra.Item
          title={freeze.error ? errorMessage(freeze.error) : freezeText(freeze.data ?? null)}
          icon={closed ? Icon.Lock : Icon.LockUnlocked}
          onAction={go("guard-status")}
        />
      </MenuBarExtra.Section>
      <MenuBarExtra.Section title="Guard">
        <MenuBarExtra.Item
          title={
            guard.error
              ? errorMessage(guard.error)
              : guard.data
                ? `Guard ${guardSummary(guard.data, now)}`
                : "Reading the guard …"
          }
          subtitle={guard.data?.lastRun ? agoText(guard.data.lastRun, now) : undefined}
          icon={guard.data?.enabled ? Icon.CheckCircle : Icon.Circle}
          onAction={go("guard-status")}
        />
      </MenuBarExtra.Section>
      <MenuBarExtra.Section>
        <MenuBarExtra.Item title="Open Costs" icon={Icon.Coins} onAction={go("costs")} />
        <MenuBarExtra.Item title="Search the Journal" icon={Icon.Book} onAction={go("journal-search")} />
        <MenuBarExtra.Item
          title="Refresh"
          icon={Icon.ArrowClockwise}
          shortcut={Keyboard.Shortcut.Common.Refresh}
          onAction={refresh}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
