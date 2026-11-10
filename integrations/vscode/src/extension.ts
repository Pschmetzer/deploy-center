// Deploy Center for VS Code, Cursor and Windsurf: what waits to go live, and a deploy by hand.
// Everything goes through the deploys CLI; nothing deploys without a click and a confirmation.

import { execFile } from "node:child_process";
import * as vscode from "vscode";
import { canPreview, canRollback, deployArgs, deployFailure, errorLine, findCli, loadProjects, makeRunner, parseDeploy, projectArgs, rollbackArgs, Runner, urlIn } from "./cli";
import { count, setTranslator, t } from "./i18n";
import { aiPrompt } from "./log";
import { describe, platformLabel, Project, statusText, summarize, followStep } from "./model";
import { parseRemotes, Scope, scopeProjects } from "./repo";

// Every text for people in the editor's language (l10n/bundle.l10n.<lang>.json), English otherwise.
setTranslator((m, ...a) => vscode.l10n.t(m, ...a));

type ViewState = "loading" | "missing" | "error" | "empty" | "nomatch" | "ok";

const SITE = "https://deploycenter.app";
/** A refresh on focus only when the last one is older than this. */
const FOCUS_STALE_MS = 60_000;

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

export class Controller implements vscode.TreeDataProvider<Project> {
  private readonly changed = new vscode.EventEmitter<Project | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  readonly output = vscode.window.createOutputChannel("Deploy Center");
  /** Build logs get their own channel: showing one does not wipe the warnings in "Deploy Center". */
  readonly logs = vscode.window.createOutputChannel(t("Deploy Center: Build log"));
  readonly status = vscode.window.createStatusBarItem("deployCenter.status", vscode.StatusBarAlignment.Left, 50);

  private cli: string | null = null;
  private run: Runner | null = null;
  private all: Project[] = [];
  shown: Project[] = [];
  matched = false;
  private warning: string | null = null;
  private state: ViewState = "loading";
  private lastRefresh = 0;
  private inFlight: Promise<void> | null = null;
  private timer: ReturnType<typeof setInterval> | undefined;

  /** Timers of follow-ups (refresh later, follow a deploy); dispose clears them. */
  private readonly pending = new Set<ReturnType<typeof setTimeout>>();
  private disposed = false;

  /** followMs: the pause between two looks at a started deploy (tests make it short). */
  constructor(private readonly followMs = 15_000) {
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

  /** A pause that ends early (false) when the controller is disposed. */
  private sleep(ms: number): Promise<boolean> {
    return new Promise((resolve) => {
      if (this.disposed) return resolve(false);
      const id = setTimeout(() => { this.pending.delete(id); resolve(!this.disposed); }, ms);
      this.pending.add(id);
    });
  }

  private refreshLater(ms = 10_000): void {
    void this.sleep(ms).then((go) => { if (go) void this.refresh(); });
  }

  dispose(): void {
    this.disposed = true;
    for (const t of this.pending) clearTimeout(t);
    this.pending.clear();
    if (this.timer) clearInterval(this.timer);
    this.status.dispose(); this.output.dispose(); this.logs.dispose(); this.changed.dispose();
  }

  refresh(): Promise<void> {
    if (!this.inFlight) this.inFlight = this.load().finally(() => { this.inFlight = null; });
    return this.inFlight;
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
      s.text = t("$(warning) deploys not found");
      s.tooltip = t("Deploy Center: the deploys command was not found. Click for options.");
      return;
    }
    if (state === "loading") { s.text = "$(sync~spin) Deploy Center"; s.tooltip = t("Reading projects…"); return; }
    if (state === "error") {
      s.text = "$(warning) Deploy Center";
      s.tooltip = t("Could not read the projects: {0}", this.warning ?? t("unknown error"));
      s.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
      return;
    }
    const sum = summarize(this.shown);
    s.text = statusText(sum);
    if (sum.failed) s.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    const md = new vscode.MarkdownString(undefined, true);
    md.appendMarkdown(`**Deploy Center** · ${this.matched ? t("this repo") : t("all projects")}\n\n`);
    if (!this.shown.length) md.appendMarkdown((state === "nomatch" ? t("No project deploys from this folder's repo.") : t("Nothing is waiting.")) + "\n\n");
    for (const p of this.shown.slice(0, 15)) md.appendText(`${p.name}: ${describe(p)}\n`).appendMarkdown("\n");
    if (this.shown.length > 15) md.appendText(t("… and {0} more", this.shown.length - 15) + "\n");
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
    item.contextValue = ["project", p.waiting && "waiting", p.failed && "failed", p.building && "building",
      canPreview(p) && "can-preview", canRollback(p) && "can-rollback"].filter(Boolean).join(" ");
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
      { label: t("$(globe) Get Deploy Center"), detail: t("The free Mac app includes the deploys command. {0}", SITE), id: "site" },
      { label: t("$(gear) Set the path to deploys"), detail: t("Settings: Deploy Center › Cli Path"), id: "settings" },
      { label: t("$(refresh) Look again"), id: "again" },
    ], { title: t("Deploy Center: the deploys command was not found") });
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
    if (this.matched && waiting.length) items.push({ label: count(waiting.length, "$(rocket) Deploy {0} waiting project of this repo…", "$(rocket) Deploy {0} waiting projects of this repo…"), id: "repo" });
    for (const p of this.shown) items.push({ label: p.name, description: describe(p), project: p });
    items.push({ label: t("$(refresh) Refresh"), id: "refresh" });
    const pick = await vscode.window.showQuickPick(items, { title: "Deploy Center", placeHolder: this.shown.length ? t("Pick a project") : t("Nothing to show") });
    if (pick?.id === "repo") return this.deployRepo();
    if (pick?.id === "refresh") return this.refresh();
    if (pick?.project) return this.projectMenu(pick.project);
  }

  async projectMenu(p: Project): Promise<void> {
    type Item = vscode.QuickPickItem & { id: string };
    const items: Item[] = [
      { label: t("$(rocket) Deploy…"), description: p.waiting ? describe(p) : t("nothing waiting"), id: "deploy" },
      { label: t("$(link-external) Open site"), id: "open" },
      { label: t("$(output) Show log"), description: p.failed ? t("the newest build failed") : undefined, id: "log" },
      { label: t("$(markdown) Copy release notes"), id: "notes" },
    ];
    if (canPreview(p)) items.splice(1, 0, { label: t("$(eye) Deploy preview…"), description: t("production stays as it is"), id: "preview" });
    if (canRollback(p)) items.push({ label: t("$(history) Roll back…"), description: t("production to the deploy before"), id: "rollback" });
    if (p.failed) items.splice(1, 0, { label: t("$(copy) Copy for AI"), description: t("the first error block, ready to paste"), id: "ai" });
    const pick = await vscode.window.showQuickPick(items, { title: `${p.name} (${platformLabel(p.platform)})` });
    switch (pick?.id) {
      case "deploy": return this.deploy(p);
      case "open": return this.open(p, false);
      case "log": return this.showLog(p);
      case "ai": return this.copyForAi(p);
      case "notes": return this.copyNotes(p);
      case "preview": return this.deployPreview(p);
      case "rollback": return this.rollback(p);
    }
  }

  private async startOne(run: Runner, p: Project): Promise<{ ok: boolean; text: string; url: string | null }> {
    const r = await run(deployArgs(p), 90_000);
    const d = parseDeploy(r.stdout);
    if (r.code === 0 && d) return { ok: true, text: t("{0}: started ({1})", p.name, d.state ?? t("queued")), url: d.url };
    return { ok: false, text: `${p.name}: ${deployFailure(r)}`, url: null };
  }

  /** Projects whose deploy dialog or start is open: a second click does not open a second one. */
  private readonly starting = new Set<string>();

  async deploy(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const key = `${p.platform}:${p.name}`;
    if (this.starting.has(key)) { void vscode.window.showInformationMessage(t("{0} is being started already.", p.name)); return; }
    this.starting.add(key);
    try { await this.deployOne(run, p); } finally { this.starting.delete(key); }
  }

  private async deployOne(run: Runner, p: Project): Promise<void> {
    const what = p.waiting ? describe(p) : t("Nothing is known to be waiting; this deploys the newest commit again.");
    const go = t("Deploy");
    const ok = await vscode.window.showWarningMessage(t("Deploy {0} to production on {1}?", p.name, platformLabel(p.platform)),
      { modal: true, detail: what }, go);
    if (ok !== go) return;
    const res = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: t("Starting {0}…", p.name) }, () => this.startOne(run, p));
    this.output.appendLine(res.text);
    if (res.ok) {
      const openIt = t("Open deploy");
      const btn = await (res.url ? vscode.window.showInformationMessage(res.text, openIt) : vscode.window.showInformationMessage(res.text));
      if (btn === openIt && res.url) void vscode.env.openExternal(vscode.Uri.parse(res.url));
    } else void vscode.window.showErrorMessage(res.text);
    if (res.ok) void this.follow(p); else this.refreshLater();
  }

  /** After a start: look every 15 s (at most 60 looks) until the build is live or failed, then say so. */
  private async follow(p: Project): Promise<void> {
    let seen = false;
    for (let looks = 1; looks <= 60; looks++) {
      if (!await this.sleep(this.followMs)) return;
      await this.refresh();
      const now = this.all.find((x) => x.platform === p.platform && x.name === p.name);
      if (now?.building) seen = true;
      const step = followStep(now, seen, looks);
      if (step === "wait") continue;
      if (step === "live") void vscode.window.showInformationMessage(t("{0} is live.", p.name));
      if (step === "failed" && now) {
        const ai = t("Copy for AI"), logBtn = t("Show log");
        const btn = await vscode.window.showErrorMessage(t("{0}: the build failed.", p.name), ai, logBtn);
        if (btn === ai) await this.copyForAi(now);
        if (btn === logBtn) await this.showLog(now);
      }
      return;
    }
  }

  /** A preview deploy (Vercel): asked first, not followed (the tree shows production). */
  async deployPreview(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    if (!canPreview(p)) { void vscode.window.showInformationMessage(t("{0} has no preview deploys here (Vercel only).", p.name)); return; }
    const go = t("Deploy preview");
    const ok = await vscode.window.showWarningMessage(t("Deploy a preview of {0}?", p.name),
      { modal: true, detail: t("Builds the newest commit at a preview address. Production stays as it is.") }, go);
    if (ok !== go) return;
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: t("Starting a preview of {0}…", p.name) },
      () => run(deployArgs(p, true), 90_000));
    const d = parseDeploy(r.stdout);
    if (r.code !== 0 || !d) { const msg = `${p.name}: ${deployFailure(r)}`; this.output.appendLine(msg); void vscode.window.showErrorMessage(msg); return; }
    const text = t("{0}: preview started ({1})", p.name, d.state ?? t("queued"));
    this.output.appendLine(text);
    const openIt = t("Open preview");
    const btn = await (d.url ? vscode.window.showInformationMessage(text, openIt) : vscode.window.showInformationMessage(text));
    if (btn === openIt && d.url) void vscode.env.openExternal(vscode.Uri.parse(d.url));
  }

  /** Production back to the deploy before the current one: a live site changes, so asked first. */
  async rollback(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    if (!canRollback(p)) { void vscode.window.showInformationMessage(t("{0} cannot be rolled back from here (Vercel and Render only).", p.name)); return; }
    const go = t("Roll back");
    const ok = await vscode.window.showWarningMessage(t("Roll back {0} on {1}?", p.name, platformLabel(p.platform)),
      { modal: true, detail: t("Production goes back to the deploy before the current one. The site changes at once.") }, go);
    if (ok !== go) return;
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: t("Rolling back {0}…", p.name) },
      () => run(rollbackArgs(p), 90_000));
    const d = parseDeploy(r.stdout);
    // Exit 0 without an answer it can read: it most likely rolled back. Saying "failed" would
    // invite a second rollback, which goes back one more deploy.
    if (r.code === 0 && !d) {
      const msg = t("{0}: the rollback ran, but its answer could not be read. Check its state (Refresh) before you roll back again.", p.name);
      this.output.appendLine(msg); void vscode.window.showWarningMessage(msg); this.refreshLater(3_000); return;
    }
    if (r.code !== 0 || !d) { const msg = `${p.name}: ${r.timedOut ? t("the rollback did not answer in time. Check its state (Refresh) before you try again.") : errorLine(r, "rollback")}`; this.output.appendLine(msg); void vscode.window.showErrorMessage(msg); return; }
    const text = d.state ? t("{0}: rolled back to {1} ({2})", p.name, d.id, d.state) : t("{0}: rolled back to {1}", p.name, d.id);
    this.output.appendLine(text);
    void vscode.window.showInformationMessage(text);
    this.refreshLater(3_000);
  }

  async deployRepo(): Promise<void> {
    const run = this.need(); if (!run) return;
    if (this.state === "loading") await this.refresh();
    const waiting = this.matched ? this.shown.filter((p) => p.waiting) : [];
    if (!waiting.length) {
      void vscode.window.showInformationMessage(this.matched ? t("Nothing of this repo is waiting.") : t("No project deploys from this folder's repo."));
      return;
    }
    const go = t("Deploy");
    const ok = await vscode.window.showWarningMessage(count(waiting.length, "Deploy {0} project of this repo to production?", "Deploy {0} projects of this repo to production?"),
      { modal: true, detail: waiting.map((p) => `• ${p.name} (${p.platform}): ${describe(p)}`).join("\n") }, go);
    if (ok !== go) return;
    const results = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: t("Starting deploys…") }, async (prog) => {
      const out = [];
      for (const p of waiting) { prog.report({ message: p.name }); out.push(await this.startOne(run, p)); }
      return out;
    });
    for (const r of results) this.output.appendLine(r.text);
    const bad = results.filter((r) => !r.ok);
    const msg = t("{0} started, {1} failed to start.", results.length - bad.length, bad.length);
    if (bad.length) void vscode.window.showErrorMessage(`${msg} ${bad.map((b) => b.text).join("; ")}`, t("Show output")).then((b) => { if (b) this.output.show(); });
    else void vscode.window.showInformationMessage(msg);
    this.refreshLater();
  }

  private async readLog(run: Runner, p: Project): Promise<string | null> {
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: t("Reading the log of {0}", p.name) },
      () => run(projectArgs("logs", p, String(cfg().logLines)), 60_000));
    if (r.code !== 0) { void vscode.window.showErrorMessage(`${p.name}: ${errorLine(r, "deploys logs")}`); return null; }
    return r.stdout;
  }

  async showLog(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const log = await this.readLog(run, p); if (log === null) return;
    this.logs.clear();
    this.logs.appendLine(`── ${p.name} (${p.platform}) · ${t("newest build log")}${p.state ? ` · ${p.state}` : ""} ──`);
    this.logs.append(log.endsWith("\n") ? log : log + "\n");
    this.logs.show(true);
    if (p.failed) {
      const b = await vscode.window.showWarningMessage(t("The newest build of {0} failed.", p.name), t("Copy for AI"));
      if (b) await this.copyForAi(p, log);
    }
  }

  async copyForAi(p: Project, log?: string): Promise<void> {
    const run = this.need(); if (!run) return;
    const text = log ?? await this.readLog(run, p); if (text === null) return;
    await vscode.env.clipboard.writeText(aiPrompt(p, text));
    void vscode.window.showInformationMessage(t("Copied the first error of {0}, ready to paste into Claude Code, Cursor or a chat.", p.name));
  }

  async copyNotes(p: Project): Promise<void> {
    const run = this.need(); if (!run) return;
    const r = await run(projectArgs("notes", p), cfg().timeoutMs);
    if (r.code !== 0 || !r.stdout.trim()) { void vscode.window.showErrorMessage(`${p.name}: ${errorLine(r, "deploys notes")}`); return; }
    await vscode.env.clipboard.writeText(r.stdout.trim() + "\n");
    void vscode.window.showInformationMessage(t("Copied the release notes of {0}.", p.name));
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
    const pick = await vscode.window.showQuickPick(list.map((p) => ({ label: p.name, description: describe(p), p })), { placeHolder: t("Pick a project") });
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
  reg("deployCenter.deployPreview", async (a) => { const p = await c.pick(a, canPreview); if (p) await c.deployPreview(p); });
  reg("deployCenter.rollback", async (a) => { const p = await c.pick(a, canRollback); if (p) await c.rollback(p); });
  reg("deployCenter.openSite", async (a) => { const p = await c.pick(a); if (p) await c.open(p, false); });
  reg("deployCenter.openDashboard", async (a) => { const p = await c.pick(a); if (p) await c.open(p, true); });
  reg("deployCenter.showLog", async (a) => { const p = await c.pick(a, (x) => x.failed || !c.shown.some((y) => y.failed)); if (p) await c.showLog(p); });
  reg("deployCenter.copyForAi", async (a) => { const p = await c.pick(a, (x) => x.failed || !c.shown.some((y) => y.failed)); if (p) await c.copyForAi(p); });
  reg("deployCenter.copyNotes", async (a) => { const p = await c.pick(a, (x) => x.waiting || !c.shown.some((y) => y.waiting)); if (p) await c.copyNotes(p); });

  const tree = vscode.window.createTreeView("deployCenter.projects", { treeDataProvider: c, showCollapseAll: false });
  context.subscriptions.push(c, tree,
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
