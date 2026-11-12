// Texts for people go through t(): in the editor that is vscode.l10n.t (l10n/bundle.l10n.*.json,
// set by extension.ts); in the unit tests the English text with {0}, {1} … filled in.

export type Translate = (message: string, ...args: (string | number | boolean)[]) => string;

const fill: Translate = (m, ...a) => m.replace(/\{(\d+)\}/g, (_x, i) => String(a[Number(i)]));
let impl: Translate = fill;

export function setTranslator(fn: Translate): void { impl = fn; }

export const t: Translate = (m, ...a) => impl(m, ...a);

/** "1 commit" or "3 commits": both forms are whole messages, so each language words its own. */
export function count(n: number, one: string, many: string): string {
  return n === 1 ? t(one, n) : t(many, n);
}
