import { Color, Icon, Keyboard, LaunchType, MenuBarExtra, launchCommand, open } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { deployCenterURL, isFailedState, platformLabel, status } from "./lib/deploys";
import { copyBuildError, errorMessage } from "./lib/ui";

// The menu bar: how many projects wait to go live, red when a newest build failed. One read of
// `deploys status --json` every 10 minutes (package.json: interval); nothing deploys from here.
export default function MenuBar() {
  const { data, error, isLoading, revalidate } = useCachedPromise(status, [], { onError: () => undefined });
  const all = data?.data ?? [];
  const failed = all.filter((p) => !p.building && isFailedState(p.state));
  const building = all.filter((p) => p.building);
  const waiting = all.filter((p) => p.changed);
  const title = error ? "!" : waiting.length ? String(waiting.length) : undefined;
  const icon = { source: Icon.Rocket, tintColor: failed.length ? Color.Red : Color.PrimaryText };
  const openWaiting = () => launchCommand({ name: "waiting-deploys", type: LaunchType.UserInitiated });

  return (
    <MenuBarExtra
      icon={icon}
      title={title}
      isLoading={isLoading}
      tooltip={
        error
          ? `Deploy Center: ${errorMessage(error)}`
          : `Deploy Center: ${waiting.length} waiting, ${failed.length} failed`
      }
    >
      {error ? <MenuBarExtra.Item title={errorMessage(error)} icon={Icon.Warning} /> : null}
      {data?.warning ? <MenuBarExtra.Item title={data.warning} icon={Icon.Warning} /> : null}
      <MenuBarExtra.Section title={failed.length ? `Failed (${failed.length})` : undefined}>
        {failed.map((p) => (
          <MenuBarExtra.Item
            key={`f/${p.platform}/${p.name}`}
            icon={{ source: Icon.XMarkCircle, tintColor: Color.Red }}
            title={p.name}
            subtitle={platformLabel(p.platform)}
            tooltip="Copy the first error of the build log"
            onAction={() => copyBuildError(p)}
          />
        ))}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section title={building.length ? `Building (${building.length})` : undefined}>
        {building.map((p) => (
          <MenuBarExtra.Item
            key={`b/${p.platform}/${p.name}`}
            icon={{ source: Icon.CircleProgress50, tintColor: Color.Blue }}
            title={p.name}
            subtitle={platformLabel(p.platform)}
            onAction={() => open(deployCenterURL(p.name))}
          />
        ))}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section title={waiting.length ? `Waiting (${waiting.length})` : undefined}>
        {waiting.map((p) => (
          <MenuBarExtra.Item
            key={`w/${p.platform}/${p.name}`}
            icon={Icon.Clock}
            title={p.name}
            subtitle={platformLabel(p.platform)}
            onAction={openWaiting}
          />
        ))}
      </MenuBarExtra.Section>
      <MenuBarExtra.Section>
        <MenuBarExtra.Item title="Open Waiting Deploys" icon={Icon.List} onAction={openWaiting} />
        <MenuBarExtra.Item
          title="Refresh"
          icon={Icon.ArrowClockwise}
          shortcut={Keyboard.Shortcut.Common.Refresh}
          onAction={revalidate}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
