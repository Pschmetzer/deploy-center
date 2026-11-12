// The German texts are complete: every t()/count() message of src/ is in l10n/bundle.l10n.de.json
// (and nothing stale), every %key% of package.json is in both package.nls files, and each
// translation keeps the {0} … placeholders of its English text.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import * as path from "node:path";
import { test } from "node:test";

const root = path.resolve(__dirname, "../..");
const read = (f: string) => readFileSync(path.join(root, f), "utf8");
const json = (f: string) => JSON.parse(read(f)) as Record<string, string>;
const holes = (s: string) => [...s.matchAll(/\{\d+\}/g)].map((m) => m[0]).sort().join();
const str = String.raw`"((?:[^"\\]|\\.)*)"`;

function messages(): Set<string> {
  const out = new Set<string>();
  for (const f of readdirSync(path.join(root, "src")).filter((x) => x.endsWith(".ts"))) {
    const src = read(`src/${f}`);
    for (const m of src.matchAll(new RegExp(String.raw`\bt\(` + str, "g"))) out.add(JSON.parse(`"${m[1]}"`));
    for (const m of src.matchAll(new RegExp(String.raw`\bcount\([^,]+,\s*` + str + String.raw`,\s*` + str, "g"))) {
      out.add(JSON.parse(`"${m[1]}"`)); out.add(JSON.parse(`"${m[2]}"`));
    }
  }
  return out;
}

test("every message of the code has a German text, and none is left over", () => {
  const de = json("l10n/bundle.l10n.de.json");
  const used = messages();
  assert.ok(used.size > 50, `found ${used.size} messages`);
  assert.deepEqual([...used].filter((m) => !(m in de)), []);
  assert.deepEqual(Object.keys(de).filter((m) => !used.has(m)), []);
  for (const [en, d] of Object.entries(de)) assert.equal(holes(d), holes(en), en);
});

test("package.json: every %key% in English and German", () => {
  const keys = [...read("package.json").matchAll(/"%([^%"]+)%"/g)].map((m) => m[1]);
  const en = json("package.nls.json"), de = json("package.nls.de.json");
  assert.ok(keys.length > 10);
  for (const k of keys) { assert.ok(en[k], `en ${k}`); assert.ok(de[k], `de ${k}`); }
  assert.deepEqual(Object.keys(de).sort(), Object.keys(en).sort());
  assert.equal(JSON.parse(read("package.json")).l10n, "./l10n");
});
