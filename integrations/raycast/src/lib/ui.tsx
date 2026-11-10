import {
  Action,
  ActionPanel,
  Alert,
  Clipboard,
  Color,
  Icon,
  Image,
  Keyboard,
  List,
  Toast,
  confirmAlert,
  open,
  openExtensionPreferences,
  showToast,
} from "@raycast/api";
import {
  DeploysError,
  DeploysErrorKind,
  deploy,
  deployCenterURL,
  openProject,
  platformLabel,
  releaseNotes,
} from "./deploys";

export const INSTALL_URL = "https://github.com/Pschmetzer/deploy-center#readme";

export function errorKind(error: unknown): DeploysErrorKind {
  return error instanceof DeploysError ? error.kind : "failed";
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const ERROR_TITLE: Record<DeploysErrorKind, string> = {
  missing: "Deploy Center's CLI was not found",
  auth: "Not logged in",
  timeout: "deploys took too long",
  failed: "deploys could not read your projects",
};

const AUTH_HINT =
  "Log in to Vercel (vercel login), save a Render key (deploys render set-key) and log in to GitHub (gh auth login). " +
  "Deploy Center's window shows what is missing.";

export function ErrorView(props: { error: unknown; onRetry: () => void }) {
  const kind = errorKind(props.error);
  const message = errorMessage(props.error);
  return (
    <List.EmptyView
      icon={{ source: Icon.Warning, tintColor: Color.Red }}
      title={ERROR_TITLE[kind]}
      description={kind === "auth" ? `${message}\n\n${AUTH_HINT}` : message}
      actions={
        <ActionPanel>
          <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={props.onRetry} />
          <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
          {kind === "missing" && <Action.OpenInBrowser title="Get Deploy Center" url={INSTALL_URL} />}
          {kind === "auth" && <Action.Open title="Open Deploy Center" target="deploycenter://" icon={Icon.AppWindow} />}
        </ActionPanel>
      }
    />
  );
}

// A row at the top of a list for "some of it could not be read".
export function WarningItem(props: { warning?: string; onRetry: () => void }) {
  if (!props.warning) return null;
  return (
    <List.Item
      icon={{ source: Icon.Warning, tintColor: Color.Orange }}
      title="Some projects could not be read"
      subtitle={props.warning.split("\n")[0]}
      accessories={[{ tooltip: props.warning, icon: Icon.Info }]}
      actions={
        <ActionPanel>
          <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={props.onRetry} />
          <Action.CopyToClipboard title="Copy Message" content={props.warning} />
        </ActionPanel>
      }
    />
  );
}

export function platformIcon(platform: string): Image.ImageLike {
  return platform === "vercel" ? { source: Icon.Globe } : { source: Icon.Cloud };
}

export function platformTag(platform: string): List.Item.Accessory {
  return {
    tag: { value: platformLabel(platform), color: platform === "vercel" ? Color.PrimaryText : Color.Purple },
  };
}

async function openWithToast(name: string, dashboard: boolean) {
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: dashboard ? "Opening dashboard" : "Opening site",
  });
  try {
    const url = await openProject(name, dashboard);
    if (url) await open(url);
    await toast.hide();
  } catch (e) {
    toast.style = Toast.Style.Failure;
    toast.title = `Could not open ${name}`;
    toast.message = errorMessage(e);
  }
}

async function copyNotes(name: string) {
  const toast = await showToast({ style: Toast.Style.Animated, title: `Reading release notes for ${name}` });
  try {
    const notes = await releaseNotes(name);
    await Clipboard.copy(notes);
    toast.style = Toast.Style.Success;
    toast.title = "Release notes copied";
    toast.message = `${notes.split("\n").filter((l) => l.startsWith("- ")).length} entries`;
  } catch (e) {
    toast.style = Toast.Style.Failure;
    toast.title = "Could not read release notes";
    toast.message = errorMessage(e);
  }
}

// One project, after the person confirmed. Shows a toast with what deploy-json answered.
export async function deployOne(p: { name: string; platform: string }, onDone?: () => void) {
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: `Deploying ${p.name}`,
    message: platformLabel(p.platform),
  });
  try {
    const r = await deploy(p);
    toast.style = Toast.Style.Success;
    toast.title = `${p.name}: deploy started`;
    toast.message = [r.state, r.url ?? r.id].filter(Boolean).join(" · ");
    if (r.url) {
      toast.primaryAction = { title: "Open Deploy", onAction: () => open(r.url as string) };
    }
    toast.secondaryAction = { title: "Show in Deploy Center", onAction: () => open(deployCenterURL(p.name)) };
  } catch (e) {
    toast.style = Toast.Style.Failure;
    toast.title = `${p.name}: deploy did not start`;
    toast.message = errorMessage(e);
  } finally {
    onDone?.();
  }
}

export async function confirmAndDeploy(p: { name: string; platform: string }, detail: string, onDone?: () => void) {
  const ok = await confirmAlert({
    title: `Deploy ${p.name}?`,
    message: `${platformLabel(p.platform)} builds the newest commit to production.${detail ? `\n\n${detail}` : ""}`,
    icon: { source: "extension-icon.png" },
    primaryAction: { title: "Deploy", style: Alert.ActionStyle.Default },
  });
  if (ok) await deployOne(p, onDone);
}

// The actions every project row shares, below the row's own primary action.
export function ProjectActions(props: { name: string; onRefresh: () => void }) {
  return (
    <>
      <ActionPanel.Section>
        <Action
          title="Open Site"
          icon={Icon.Globe}
          shortcut={Keyboard.Shortcut.Common.Open}
          onAction={() => openWithToast(props.name, false)}
        />
        <Action
          title="Open Dashboard"
          icon={Icon.AppWindowGrid2x2}
          shortcut={Keyboard.Shortcut.Common.OpenWith}
          onAction={() => openWithToast(props.name, true)}
        />
        <Action
          title="Copy Release Notes"
          icon={Icon.Clipboard}
          shortcut={Keyboard.Shortcut.Common.Copy}
          onAction={() => copyNotes(props.name)}
        />
        <Action.Open
          title="Show in Deploy Center"
          icon={{ source: "extension-icon.png" }}
          target={deployCenterURL(props.name)}
          shortcut={{ modifiers: ["cmd"], key: "d" }}
        />
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action.CopyToClipboard
          title="Copy Project Name"
          content={props.name}
          shortcut={Keyboard.Shortcut.Common.CopyName}
        />
        <Action
          title="Refresh"
          icon={Icon.ArrowClockwise}
          shortcut={Keyboard.Shortcut.Common.Refresh}
          onAction={props.onRefresh}
        />
      </ActionPanel.Section>
    </>
  );
}
