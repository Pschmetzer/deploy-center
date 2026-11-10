// Deploy Center for VS Code, Cursor and Windsurf: what waits to go live, and a deploy by hand.
// Everything goes through the deploys CLI; nothing deploys without a click and a confirmation.

import { execFile } from "node:child_process";
import * as vscode from "vscode";
import { deployArgs, errorLine, findCli, loadProjects, makeRunner, parseDeploy, projectArgs, Runner, urlIn } from "./cli";
import { coalesce } from "./coalesce";
import { aiPrompt } from "./log";
import { describe, platformLabel, plural, Project, statusText, summarize } from "./model";
import { parseRemotes, Scope, scopeProjects } from "./repo";

type ViewState = "loading" | "missing" | "error" | "empty" | "nomatch" | "ok";

const SITE = "https://deploycenter.app";
/** A refresh on focus only when the last one is older than this. */
const FOCUS_STALE_MS = 60_000;
/** Build logs open as documents of this scheme: read-only, never saved, no "unsaved" prompt. */
const LOG_SCHEME = "deploy-center-log";

function cfg() {
  const c = vscode.workspace.getConfiguration("deployCenter");
  return {
    cliPath: c.get<string>("cliPath", ""),
    scope: c.get<Scope>("scope", "auto"),
    pollMs: Math.max(1, c.get<number>("pollMinutes", 5)) * 60_000,
    timeoutMs: Math.max(10, c.get<number>("timeoutSeconds", 120)) * 1000,
    logLines: Math.max(20, Math.floor(c.get<number>("logLines", 200))),
  };
}

/** The remotes of every open folder (`git remote -v`), for matching projects to this window. */
function workspaceRemotes(): Promise<string[]> {
  const folders = (vscode.workspace.workspaceFolders ?? []).filter((f) => f.uri.scheme === "file");
  return Promise.all(folders.map((f) => new Promise<string[]>((resolve) => {
    execFile("git", ["-C", f.uri.fsPath, "remote", "-v"], { timeout: 5000, windowsHide: true },
      (err, stdout) => resolve(err ? [] : parseRemotes(String(stdout))));
  }))).then((all) => [...new Set(all.flat())]);
}

class Controller implements vscode.TreeDataProvider<Project> {
  private readonly changed = new vscode.EventEmitter<Project | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  readonly output = vscode.window.createOutputChannel("Deploy Center");
  readonly status = vscode.window.createStatusBarItem("deployCenter.status", vscode.StatusBarAlignment.Left, 50);

  private cli: string | null = null;
  private run: Runner | null = null;
  private all: Project[] = [];
  shown: Project[] = [];
  matched = false;
  private warning: string | null = null;
  private state: ViewState = "loading";
  private lastRefresh = 0;
  /** One read at a time; a call during one (a changed setting) reads once more after it. */
  readonly refresh = coalesce(() => this.load());
  /** Build logs, shown as read-only documents (deploy-center-log:/…), so the output channel keeps its history. */
  private readonly logs = new Map<string, string>();
  private readonly logChanged = new vscode.EventEmitter<vscode.Uri>();
  readonly logProvider: vscode.TextDocumentContentProvider = {
    onDidChange: this.logChanged.event,
    provideTextDocumentContent: (uri) => this.logs.get(uri.path) ?? "",
  };
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor() {
    this.status.name = "Deploy Center";
    this.status.command = "deployCenter.menu";
    this.status.text = "$(sync~spin) Deploy Center";
    this.status.show();
    this.locate();
  }

  locate(): void {
    this.cli = findCli({ setting: cfg().cliPath });
    this.run = this.cli ? makeRunner(this.cli) : null;
  }

  schedule(): void {
    if (this.timer) clearInterval(this.timer);
    // Gently: only while this window has focus. Coming back to it refreshes if it is stale.
    this.timer = setInterval(() => { if (vscode.window.state.focused) void this.refresh(); }, cfg().pollMs);
  }

  onFocus(): void {
    if (Date.now() - this.lastRefresh > FOCUS_STALE_MS) void this.refresh();
  }

  dispose(): void {
    if (this.timer) clearInterval(this.timer);
    this.status.dispose(); this.output.dispose(); this.changed.dispose(); this.logChanged.dispose();
  }

  private async load(): Promise<void> {
    this.lastRefresh = Date.now();
    if (!this.run) this.locate();
    if (!this.run) { this.all = []; this.warning = null; return this.render("missing"); }
    if (this.state === "loading" || this.state === "missing") this.render("loading");
    this.status.text = this.status.text.replace(/^\$\([^)]*\)/, "$(sync~spin)");
    const [loaded, remotes] = await Promise.all([loadProjects(this.run, cfg().timeoutMs), workspaceRemotes()]);
    this.all = loaded.projects;
    this.warning = loaded.warning;
    if (loaded.warning) this.output.appendLine(`[${new Date().toLocaleTimeString()}] ${loaded.warning}`);
    const scoped = scopeProjects(this.all, remotes, cfg().scope);
    this.shown = scoped.projects;
    this.matched = scoped.matched;
    if (loaded.failed) return this.render("error");
    if (!this.shown.length) return this.render(this.all.length && cfg().scope === "repo" ? "nomatch" : "empty");
    this.render("ok");
  }

  private render(state: ViewState): void {
    this.state = state;
    void vscode.commands.executeCommand("setContext", "deployCenter.state", state);
    void vscode.commands.executeCommand("setContext", "deployCenter.repoWaiting", this.matched && this.shown.some((p) => p.waiting));
    this.changed.fire(undefined);
    const s = this.status;
    s.backgroundColor = undefined;
    if (state === "missing") {
      s.text = "$(warning) deploys not found";
      s.tooltip = "Deploy Center: the deploys command was not found. Click for options.";
      return;
    }
    if (state === "loading") { s.text = "$(sync~spin) Deploy Center"; s.tooltip = "Reading projects…"; return; }
    if (state === "error") {
      s.text = "$(warning) Deploy Center";
      s.tooltip = `Could not read the projects: ${this.warning ?? "unknown error"}`;
      s.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
      return;
    }
    const sum = summarize(this.shown);
    s.text = statusText(sum);
    if (sum.failed) s.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    const md = new vscode.MarkdownString(undefined, true);
    md.appendMarkdown(`**Deploy Center** · ${this.matched ? "this repo" : "all projects"}\n\n`);
    if (!this.shown.length) md.appendMarkdown(state === "nomatch" ? "No project deploys from this folder's repo.\n\n" : "Nothing is waiting.\n\n");
    for (const p of this.shown.slice(0, 15)) md.appendText(`${p.name}: ${describe(p)}\n`).appendMarkdown("\n");
    if (this.shown.length > 15) md.appendText(`… and ${this.shown.length - 15} more\n`);
    if (this.warning) md.appendMarkdown("\n").appendText(`⚠ ${this.warning}`);
    s.tooltip = md;
  }

  // ---- tree ----

  getChildren(el?: Project): Project[] {
    return el || this.state !== "ok" ? [] : this.shown;
  }

  getTreeItem(p: Project): vscode.TreeItem {
    const item = new vscode.TreeItem(p.name, vscode.TreeItemCollapsibleState.None);
    item.id = `${p.platform}:${p.name}`;
    item.description = describe(p);
    item.tooltip = `${p.name} (${platformLabel(p.platform)})${p.repo ? `\n${p.repo}` : ""}\n${describe(p)}`;
    item.iconPath = p.failed ? new vscode.ThemeIcon("error", new vscode.ThemeColor("errorForeground"))
      : p.building ? new vscode.ThemeIcon("sync~spin")
      : p.waiting ? new vscode.ThemeIcon("clock", new vscode.ThemeColor("charts.yellow"))
      : new vscode.ThemeIcon("check", new vscode.ThemeColor("charts.green"));
    item.contextValue = ["project", p.waiting && "waiting", p.failed && "failed", p.building && "building"].filter(Boolean).join(" ");
    item.command = { command: "deployCenter.menu", title: "Actions", arguments: [p] };
    return item;
  }

  // ---- actions ----

  private need(): Runner | null {
    if (this.run) return this.run;
    void this.missingMenu();
    return null;
  }

  async missingMenu(): Promise<void> {
    const pick = await vscode.window.showQuickPick([
      { label: "$(globe) Get Deploy Center", detail: `The free Mac app includes the deploys command. ${SITE}`, id: "site" },
      { label: "$(gear) Set the path to deploys", detail: "Settings: Deploy Center › Cli Path", id: "settings" },
      { label: "$(refresh) Look again", id: "again" },
    ], { title: "Deploy Center: the deploys command was not found" });
    if (pick?.id === "site") void vscode.env.openExternal(vscode.Uri.parse(SITE));
    if (pick?.id === "settings") void vscode.commands.executeCommand("workbench.action.openSettings", "deployCenter.cliPath");
    if (pick?.id === "again") { this.locate(); void this.refresh(); }
  }

  /** The status bar click: one project's actions, or first which project. */
  async menu(project?: Project): Promise<void> {
    if (!this.run && this.state === "missing") return this.missingMenu();
    if (project) return this.projectMenu(project);
    if (this.shown.length === 1) return this.projectMenu(this.shown[0]);
    type Item = vscode.QuickPickItem & { project?: Project; id?: string };
    const items: Item[] = [];
    const waiting = this.shown.filter((p) => p.waiting);
    if (this.matched && waiting.length) items.push({ label: `$(rocket) Deploy ${plural(waiting.length, "waiting project")} of this repo…`, id: "repo" });
    for (const p of this.shown) items.push({ label: p.name, description: describe(p), project: p });
    items.push({ label: "$(refresh) Refresh", id: "refresh" });
    const pick = await vscode.window.showQuickPick(items, { title: "Deploy Center", placeHolder: this.shown.length ? "Pick a project" : "Nothing to show" });
    if (pick?.id === "repo") return this.deployRepo();
    if (pick?.id === "refresh") return this.refresh();
    if (pick?.project) return this.projectMenu(pick.project);
  }

  async projectMenu(p: Project): Promise<void> {
    type Item = vscode.QuickPickItem & { id: string };
    const items: Item[] = [
      { label: "$(rocket) Deploy…", description: p.waiting ? describe(p) : "nothing waiting", id: "deploy" },
      { label: "$(link-external) Open site", id: "open" },
      { label: "$(output) Show log", description: p.failed ? "the newest build failed" : undefined, id: "log" },
      { label: "$(markdown) Copy release notes", id: "notes" },
    ];
    if (p.failed) items.splice(1, 0, { label: "$(copy) Copy for AI", description: "the first error block, ready to paste", id: "ai" });
    const pick = await vscode.window.showQuickPick(items, { title: `${p.name} (${platformLabel(p.platform)})` });
    switch (pick?.id) {
      case "deploy": return this.deploy(p);
      case "open": return this.open(p, false);
      case "log": return this.showLog(p);
      case "ai": return this.copyForAi(p);
      case "notes": return this.copyNotes(p);
    }
  }

  private async startOne(run: Runner, p: Project): Promise<{ ok: boolean; text: string; url: string | null }> {
    const r = await run(deployArgs(p), 90_000);
    const d = parseDeploy(r.stdout);
    if (r.code === 0 && d) return { ok: true, text: `${p.name}: started (${d.state ?? "queued"})`, url: d.url };
    return { ok: false, text: `${p.name}: ${errorLine(r, "deploy")}`, url: null };
  }

  async deploy(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const what = p.waiting ? describe(p) : "Nothing is known to be waiting; this deploys the newest commit again.";
    const ok = await vscode.window.showWarningMessage(`Deploy ${p.name} to production on ${platformLabel(p.platform)}?`,
      { modal: true, detail: what }, "Deploy");
    if (ok !== "Deploy") return;
    const res = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: `Starting ${p.name}…` }, () => this.startOne(run, p));
    this.output.appendLine(res.text);
    if (res.ok) {
      const btn = await (res.url ? vscode.window.showInformationMessage(res.text, "Open deploy") : vscode.window.showInformationMessage(res.text));
      if (btn === "Open deploy" && res.url) void vscode.env.openExternal(vscode.Uri.parse(res.url));
    } else void vscode.window.showErrorMessage(res.text);
    setTimeout(() => void this.refresh(), 10_000);
  }

  async deployRepo(): Promise<void> {
    const run = this.need(); if (!run) return;
    if (this.state === "loading") await this.refresh();
    const waiting = this.matched ? this.shown.filter((p) => p.waiting) : [];
    if (!waiting.length) {
      void vscode.window.showInformationMessage(this.matched ? "Nothing of this repo is waiting." : "No project deploys from this folder's repo.");
      return;
    }
    const ok = await vscode.window.showWarningMessage(`Deploy ${plural(waiting.length, "project")} of this repo to production?`,
      { modal: true, detail: waiting.map((p) => `• ${p.name} (${p.platform}): ${describe(p)}`).join("\n") }, "Deploy");
    if (ok !== "Deploy") return;
    const results = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Starting deploys…" }, async (prog) => {
      const out = [];
      for (const p of waiting) { prog.report({ message: p.name }); out.push(await this.startOne(run, p)); }
      return out;
    });
    for (const r of results) this.output.appendLine(r.text);
    const bad = results.filter((r) => !r.ok);
    const msg = `${results.length - bad.length} started, ${bad.length} failed to start.`;
    if (bad.length) void vscode.window.showErrorMessage(`${msg} ${bad.map((b) => b.text).join("; ")}`, "Show output").then((b) => { if (b) this.output.show(); });
    else void vscode.window.showInformationMessage(msg);
    setTimeout(() => void this.refresh(), 10_000);
  }

  private async readLog(run: Runner, p: Project): Promise<string | null> {
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: `Reading the log of ${p.name}` },
      () => run(projectArgs("logs", p, String(cfg().logLines)), 60_000));
    if (r.code !== 0) { void vscode.window.showErrorMessage(`${p.name}: ${errorLine(r, "deploys logs")}`); return null; }
    return r.stdout;
  }

  async showLog(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const log = await this.readLog(run, p); if (log === null) return;
    // A read-only document per project: the output channel keeps its warnings and deploy results.
    const head = `── ${p.name} (${platformLabel(p.platform)}) · newest build log${p.state ? ` · ${p.state}` : ""} · ${new Date().toLocaleTimeString()} ──\n`;
    const uri = vscode.Uri.from({ scheme: LOG_SCHEME, path: `/${p.platform}/${p.name}.log` });
    this.logs.set(uri.path, head + (log.endsWith("\n") ? log : log + "\n"));
    this.logChanged.fire(uri);
    const doc = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: true });
    this.output.appendLine(`[${new Date().toLocaleTimeString()}] Opened the build log of ${p.name}.`);
    if (p.failed) {
      const b = await vscode.window.showWarningMessage(`The newest build of ${p.name} failed.`, "Copy for AI");
      if (b) await this.copyForAi(p, log);
    }
  }

  async copyForAi(p: Project, log?: string): Promise<void> {
    const run = this.need(); if (!run) return;
    const text = log ?? await this.readLog(run, p); if (text === null) return;
    await vscode.env.clipboard.writeText(aiPrompt(p, text));
    void vscode.window.showInformationMessage(`Copied the first error of ${p.name}, ready to paste into Claude Code, Cursor or a chat.`);
  }

  async copyNotes(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const r = await run(projectArgs("notes", p), cfg().timeoutMs);
    if (r.code !== 0 || !r.stdout.trim()) { void vscode.window.showErrorMessage(`${p.name}: ${errorLine(r, "deploys notes")}`); return; }
    await vscode.env.clipboard.writeText(r.stdout.trim() + "\n");
    void vscode.window.showInformationMessage(`Copied the release notes of ${p.name}.`);
  }

  async open(p: Project, dashboard: boolean): Promise<void> {
    const run = this.need(); if (!run) return;
    const r = await run(projectArgs("open", p, ...(dashboard ? ["--dashboard"] : [])), 30_000);
    if (r.code !== 0) { void vscode.window.showErrorMessage(`${p.name}: ${errorLine(r, "deploys open")}`); return; }
    // On a Mac the CLI has opened the browser already; elsewhere it prints the address.
    const url = urlIn(r.stdout);
    if (url) void vscode.env.openExternal(vscode.Uri.parse(url));
  }

  /** A project from a tree item or command argument; asked for when called from the palette. */
  async pick(arg: unknown, filter: (p: Project) => boolean = () => true): Promise<Project | undefined> {
    if (arg && typeof arg === "object" && "name" in arg && "platform" in arg) return arg as Project;
    const list = this.shown.filter(filter);
    if (list.length === 1) return list[0];
    const pick = await vscode.window.showQuickPick(list.map((p) => ({ label: p.name, description: describe(p), p })), { placeHolder: "Pick a project" });
    return pick?.p;
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const c = new Controller();
  const reg = (id: string, fn: (...a: unknown[]) => unknown) => context.subscriptions.push(vscode.commands.registerCommand(id, fn));
  reg("deployCenter.refresh", () => c.refresh());
  reg("deployCenter.menu", (p) => c.menu(p as Project | undefined));
  reg("deployCenter.deployRepo", () => c.deployRepo());
  reg("deployCenter.deployProject", async (a) => { const p = await c.pick(a); if (p) await c.deploy(p); });
  reg("deployCenter.openSite", async (a) => { const p = await c.pick(a); if (p) await c.open(p, false); });
  reg("deployCenter.openDashboard", async (a) => { const p = await c.pick(a); if (p) await c.open(p, true); });
  reg("deployCenter.showLog", async (a) => { const p = await c.pick(a, (x) => x.failed || !c.shown.some((y) => y.failed)); if (p) await c.showLog(p); });
  reg("deployCenter.copyForAi", async (a) => { const p = await c.pick(a, (x) => x.failed || !c.shown.some((y) => y.failed)); if (p) await c.copyForAi(p); });
  reg("deployCenter.copyNotes", async (a) => { const p = await c.pick(a, (x) => x.waiting || !c.shown.some((y) => y.waiting)); if (p) await c.copyNotes(p); });

  const tree = vscode.window.createTreeView("deployCenter.projects", { treeDataProvider: c, showCollapseAll: false });
  context.subscriptions.push(c, tree,
    vscode.workspace.registerTextDocumentContentProvider(LOG_SCHEME, c.logProvider),
    vscode.window.onDidChangeWindowState((s) => { if (s.focused) c.onFocus(); }),
    vscode.workspace.onDidChangeWorkspaceFolders(() => void c.refresh()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("deployCenter")) return;
      if (e.affectsConfiguration("deployCenter.cliPath")) c.locate();
      if (e.affectsConfiguration("deployCenter.pollMinutes")) c.schedule();
      void c.refresh();
    }));
  c.schedule();
  void c.refresh();
}

export function deactivate(): void {}
