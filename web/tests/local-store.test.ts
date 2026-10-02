// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { JsonRepository } from "../src/lib/local-repository.ts";
import { MAX_ARCHIVE_BYTES, parseDocument, parseRecord, serializeDocument, weekKey } from "../src/lib/score-record.ts";
import { randomUUID } from "node:crypto";
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
test("timestamps carry a timezone and normalize identically across platforms", () => {
  assert.throws(() => parseRecord({ ...record, createdAt: "2026-10-02T12:00:00" }));
  assert.throws(() => parseRecord({ ...record, createdAt: "2026-10-02" }));
  assert.equal(parseRecord({ ...record, createdAt: "2026-09-30T21:00:00+09:00" }).createdAt, record.createdAt);
});
test("archive size counts UTF-8 bytes independently of the record limit", () => {
  const records = Array.from({ length: 360 }, () => ({ ...record, id: randomUUID(), songId: "가".repeat(500), title: "나".repeat(200), artist: "다".repeat(200) }));
  const document = { schemaVersion: 1, records };
  assert.ok(Buffer.byteLength(JSON.stringify(document)) > MAX_ARCHIVE_BYTES);
  assert.throws(() => parseDocument(document));
  const encoded = serializeDocument(records.slice(0, 300));
  assert.ok(Buffer.byteLength(encoded) < MAX_ARCHIVE_BYTES);
  assert.equal(parseDocument(JSON.parse(encoded)).records.length, 300);
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

test("active writers stay locked; a killed writer is recovered by concurrent processes", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cono-lock-recovery-"));
  const repository = new JsonRepository(dir);
  await repository.update((data) => { data.profiles.original = { nickname: "보존" }; });
  const source = new URL("../src/lib/local-repository.ts", import.meta.url).href;
  const child = spawn(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e", `
    import { JsonRepository } from ${JSON.stringify(source)};
    import { writeSync } from 'node:fs';
    await new JsonRepository(process.argv[1]).update((data) => {
      data.profiles.uncommitted = { nickname: 'must not persist' };
      writeSync(1, 'locked\\n');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
    });
  `, dir], { stdio: ["ignore", "pipe", "pipe"] });
  try {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Child writer did not acquire its lock")), 8000);
      child.stdout.once("data", () => { clearTimeout(timer); resolve(); });
      child.once("error", (error) => { clearTimeout(timer); reject(error); });
      child.once("exit", () => { clearTimeout(timer); reject(new Error("Child writer exited before locking")); });
    });
    await assert.rejects(repository.update((data) => { data.profiles.stolen = { nickname: "must not persist" }; }), /다른 저장 작업/);
    assert.deepEqual(Object.keys((await repository.read()).profiles), ["original"]);
    const terminated = once(child, "exit");
    child.kill("SIGKILL");
    await terminated;
    await Promise.all(Array.from({ length: 8 }, (_, i) => new JsonRepository(dir).update((data) => { data.profiles[`recovered-${i}`] = { nickname: `복구${i}` }; })));
    const saved = (await repository.read()).profiles;
    assert.equal(Object.keys(saved).length, 9);
    assert.equal(saved.original.nickname, "보존");
    assert.equal(saved.uncommitted, undefined);
    assert.equal(saved.stolen, undefined);
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const terminated = once(child, "exit"); child.kill("SIGKILL"); await terminated;
    }
    await rm(dir, { recursive: true, force: true });
  }
});

test("an interrupted v2 release recovers, while an unowned legacy lock is preserved", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cono-lock-format-"));
  try {
    await mkdir(path.join(dir, ".write-lock-v2"));
    await new JsonRepository(dir).update((data) => { data.profiles.test = { nickname: "saved" }; });
    const before = await readFile(path.join(dir, "store.json"), "utf8");
    await mkdir(path.join(dir, ".write-lock"));
    await assert.rejects(new JsonRepository(dir).update((data) => { data.profiles.invalid = { nickname: "do not write" }; }), /이전 버전/);
    assert.equal(await readFile(path.join(dir, "store.json"), "utf8"), before);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
