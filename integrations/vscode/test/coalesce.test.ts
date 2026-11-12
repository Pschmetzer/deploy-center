import assert from "node:assert/strict";
import { test } from "node:test";
import { coalesce } from "../src/coalesce";

const tick = () => new Promise((r) => setTimeout(r, 5));

test("a refresh during a refresh runs once more afterwards, with what is current then", async () => {
  const seen: string[] = [];
  let setting = "auto";
  const refresh = coalesce(async () => { const s = setting; await tick(); seen.push(s); });
  const first = refresh();
  setting = "repo";
  const second = refresh();
  const third = refresh();
  assert.equal(second, first, "the running refresh is shared");
  assert.equal(third, first);
  await first;
  assert.deepEqual(seen, ["auto", "repo"], "one more read, not one per call");
});

test("no overlap, and a later call starts fresh", async () => {
  let running = 0, most = 0, n = 0;
  const refresh = coalesce(async () => { running++; most = Math.max(most, running); n++; await tick(); running--; });
  await Promise.all([refresh(), refresh()]);
  await refresh();
  assert.equal(most, 1);
  assert.equal(n, 3);
});

test("a failing read does not block the next one", async () => {
  let fail = true;
  const refresh = coalesce(async () => { await tick(); if (fail) throw new Error("x"); });
  await assert.rejects(refresh());
  fail = false;
  await refresh();
});
