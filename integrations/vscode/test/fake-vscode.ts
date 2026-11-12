// A stand-in for the `vscode` module, for the controller tests (esbuild aliases `vscode` to this
// file with --tests). Only what extension.ts uses. Dialogs answer from `answers`; every call is
// recorded in `calls`, so a test can check what the user would have seen.

type Fn = (...a: any[]) => any;

export const calls: { kind: string; args: any[] }[] = [];
/** The next answers of the dialogs, in order: a button label, a quick-pick item's label prefix, or undefined. */
export const answers: { warning: (string | undefined)[]; pick: (string | undefined)[] } = { warning: [], pick: [] };
export const settings: Record<string, unknown> = {};
export const commandsRun: Record<string, Fn> = {};
export const clipboardText = { value: "" };
export const opened: string[] = [];

export function reset(): void {
  calls.length = 0; answers.warning = []; answers.pick = [];
  for (const k of Object.keys(settings)) delete settings[k];
  clipboardText.value = ""; opened.length = 0;
}

const record = (kind: string) => (...args: any[]) => { calls.push({ kind, args }); return Promise.resolve(undefined); };

export class EventEmitter<T> {
  private fns: ((v: T) => void)[] = [];
  readonly event = (fn: (v: T) => void) => { this.fns.push(fn); return { dispose() {} }; };
  fire(v: T): void { for (const f of this.fns) f(v); }
  dispose(): void { this.fns = []; }
}

export class ThemeColor { constructor(readonly id: string) {} }
export class ThemeIcon { constructor(readonly id: string, readonly color?: ThemeColor) {} }
export enum TreeItemCollapsibleState { None = 0 }
export class TreeItem {
  id?: string; description?: string; tooltip?: unknown; iconPath?: unknown; contextValue?: string; command?: unknown;
  constructor(readonly label: string, readonly collapsibleState: TreeItemCollapsibleState) {}
}
export class MarkdownString {
  value = "";
  appendMarkdown(s: string): this { this.value += s; return this; }
  appendText(s: string): this { this.value += s; return this; }
}
export enum StatusBarAlignment { Left = 1 }
export enum ProgressLocation { Window = 10, Notification = 15 }
export const Uri = {
  parse: (s: string) => ({ toString: () => s }),
  from: (c: { scheme: string; path: string }) => ({ scheme: c.scheme, path: c.path, toString: () => `${c.scheme}:${c.path}` }),
};

function channel(name: string) {
  return { name, text: "", appendLine(s: string) { this.text += s + "\n"; }, append(s: string) { this.text += s; }, clear() { this.text = ""; }, show() {}, dispose() {} };
}

export const window = {
  state: { focused: true },
  channels: [] as ReturnType<typeof channel>[],
  createOutputChannel(name: string) { const c = channel(name); window.channels.push(c); return c; },
  createStatusBarItem() { return { name: "", text: "", tooltip: undefined as unknown, command: "", backgroundColor: undefined as unknown, show() {}, dispose() {} }; },
  createTreeView() { return { dispose() {} }; },
  showInformationMessage: record("info"),
  showErrorMessage: record("error"),
  showWarningMessage(...args: any[]) { calls.push({ kind: "warning", args }); return Promise.resolve(answers.warning.shift()); },
  showQuickPick(items: { label: string }[], opts: unknown) {
    calls.push({ kind: "pick", args: [items.map((i) => i.label), opts] });
    const want = answers.pick.shift();
    return Promise.resolve(want === undefined ? undefined : items.find((i) => i.label.includes(want)));
  },
  withProgress(_o: unknown, task: (p: { report(v: unknown): void }) => Promise<unknown>) { return task({ report() {} }); },
  onDidChangeWindowState() { return { dispose() {} }; },
  showTextDocument(doc: unknown) { calls.push({ kind: "showDoc", args: [doc] }); return Promise.resolve(); },
};

export const workspace = {
  workspaceFolders: undefined as unknown,
  getConfiguration() { return { get: <T>(k: string, d: T): T => (k in settings ? settings[k] as T : d) }; },
  onDidChangeWorkspaceFolders() { return { dispose() {} }; },
  onDidChangeConfiguration() { return { dispose() {} }; },
  registerTextDocumentContentProvider() { return { dispose() {} }; },
  openTextDocument(uri: unknown) { calls.push({ kind: "openDoc", args: [uri] }); return Promise.resolve({ uri }); },
};

export const commands = {
  executeCommand: (...args: any[]) => { calls.push({ kind: "command", args }); return Promise.resolve(); },
  registerCommand(id: string, fn: Fn) { commandsRun[id] = fn; return { dispose() {} }; },
};

export const env = {
  openExternal(u: { toString(): string }) { opened.push(u.toString()); return Promise.resolve(true); },
  clipboard: { writeText(s: string) { clipboardText.value = s; return Promise.resolve(); } },
};

/** As vscode.l10n.t without a bundle: the English text with {0}, {1} … filled in. */
export const l10n = {
  t(msg: string, ...args: unknown[]): string { return msg.replace(/\{(\d+)\}/g, (_m, i) => String(args[Number(i)])); },
};
