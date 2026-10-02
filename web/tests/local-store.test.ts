// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { JsonRepository } from "../src/lib/local-repository.ts";
import { parseDocument, parseRecord, weekKey } from "../src/lib/score-record.ts";
const fixture = JSON.parse(await readFile(new URL("../../docs/fixtures/score-v1.json", import.meta.url), "utf8"));
const record = parseDocument(fixture).records[0];

test("shared native/web schema rejects unsupported, inconsistent, and duplicate records", () => {
  assert.equal(record.score, 92);
  assert.throws(() => parseRecord({ ...record, score: 101 }));
  assert.throws(() => parseRecord({ ...record, notesHit: 27 }));
  assert.throws(() => parseRecord({ ...record, bestStreak: 24 }));
  assert.throws(() => parseRecord({ ...record, notesTotal: 0 }));
  assert.throws(() => parseRecord({ ...record, createdAt: "2099-01-01T00:00:00Z" }));
  assert.throws(() => parseDocument({ ...fixture, schemaVersion: 2 }));
  assert.throws(() => parseDocument({ schemaVersion: 1, records: [record, record] }));
  assert.throws(() => parseDocument(null));
});
test("week rolls over at Monday midnight in Seoul, including year boundary", () => {
  assert.equal(weekKey(new Date("2026-10-04T14:59:59Z")), "2026-09-28");
  assert.equal(weekKey(new Date("2026-10-04T15:00:00Z")), "2026-10-05");
  assert.equal(weekKey(new Date("2027-01-01T00:00:00Z")), "2026-12-28");
});
test("concurrent processes do not lose updates; reload persists", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cono-store-"));
  try {
    await Promise.all(Array.from({ length: 12 }, (_, i) => new JsonRepository(dir).update((data) => { data.profiles[`user-${i}`] = { nickname: `가수${i}` }; })));
    assert.equal(Object.keys((await new JsonRepository(dir).read()).profiles).length, 12);
    const before = await readFile(path.join(dir, "store.json"), "utf8");
    await assert.rejects(new JsonRepository(dir).update((data) => { data.profiles.broken = { nickname: "should not save" }; throw new Error("rollback"); }));
    assert.equal(await readFile(path.join(dir, "store.json"), "utf8"), before);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
test("corrupt and unsupported store is preserved, never reset on write", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cono-corrupt-"));
  try {
    for (const content of ["{ broken", JSON.stringify({ schemaVersion: 2, profiles: {}, scores: [], feedback: [] })]) {
      await writeFile(path.join(dir, "store.json"), content);
      await assert.rejects(new JsonRepository(dir).update((data) => { data.profiles.test = { nickname: "test" }; }));
      assert.equal(await readFile(path.join(dir, "store.json"), "utf8"), content);
    }
  } finally { await rm(dir, { recursive: true, force: true }); }
});
