// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { StemPlayer } from "../src/fx/stems.ts";
import { PendingScoreStore, PENDING_SCORE_PREFIX } from "../src/lib/pending-scores.ts";
import type { ScoreRecord } from "../src/lib/score-record.ts";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function audioHarness() {
  const resumes: ReturnType<typeof deferred<void>>[] = [];
  const starts: { offset: number; level: number }[] = [];
  const context = {
    currentTime: 10,
    destination: {},
    resume: () => { const pending = deferred<void>(); resumes.push(pending); return pending.promise; },
    decodeAudioData: async () => ({ duration: 20 }),
    createGain: () => ({
      gain: { value: 0, cancelScheduledValues() {}, setValueAtTime() {}, setValueCurveAtTime() {} },
      connect() {}, disconnect() {},
    }),
    createBufferSource: () => {
      let output: { gain: { value: number } };
      return { buffer: null, loop: false, connect(gain: typeof output) { output = gain; }, start(_at: number, offset: number) { starts.push({ offset, level: output.gain.value }); }, stop() {} };
    },
  };
  return { context: context as unknown as AudioContext, resumes, starts };
}

test("loading preserves the last stem mode and waits for audio resume", async (t) => {
  const response = deferred<Response>();
  t.mock.method(globalThis, "fetch", () => response.promise.then((value) => value.clone()));
  const audio = audioHarness();
  const player = new StemPlayer(audio.context, { mix: "/mode-mix", vocal: "/mode-vocal" });
  const start = player.start(4);
  player.setMode("vocal");
  response.resolve(new Response(new Uint8Array([1])));
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.deepEqual(audio.starts, []);
  audio.resumes[0].resolve();
  assert.equal(await start, true);
  assert.equal(player.currentMode, "vocal");
  assert.deepEqual(audio.starts, [{ offset: 4, level: 1 }, { offset: 4, level: 0 }]);
});

test("cancelled loading cannot start after a same-player restart", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response(new Uint8Array([1])));
  const audio = audioHarness();
  const player = new StemPlayer(audio.context, { mix: "/restart" });
  const old = player.start(2);
  player.pause();
  const current = player.start(8);
  audio.resumes[1].resolve();
  assert.equal(await current, true);
  audio.resumes[0].resolve();
  assert.equal(await old, false);
  assert.deepEqual(audio.starts, [{ offset: 8, level: 1 }]);
});

test("a discarded player's late failure cannot replace the current UI state", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response(new Uint8Array([1])));
  const audio = audioHarness();
  const player = new StemPlayer(audio.context, { mix: "/disposed" });
  const start = player.start();
  player.dispose();
  audio.resumes[0].reject(new Error("old resume failed"));
  assert.equal(await start, false);
  assert.equal(audio.starts.length, 0);
});

test("current audio failure is surfaced and a later attempt can retry", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response(new Uint8Array([1])));
  const audio = audioHarness();
  const player = new StemPlayer(audio.context, { mix: "/failure-retry" });
  const start = player.start();
  audio.resumes[0].reject(new Error("resume failed"));
  await assert.rejects(start, /resume failed/);
  const retry = player.start();
  audio.resumes[1].resolve();
  assert.equal(await retry, true);
  assert.equal(audio.starts.length, 1);
});

class MemoryStorage {
  values = new Map<string, string>();
  failWrite = false;
  failRemove = false;
  get length() { return this.values.size; }
  key(index: number) { return [...this.values.keys()][index] ?? null; }
  getItem(key: string) { return this.values.get(key) ?? null; }
  setItem(key: string, value: string) { if (this.failWrite) throw new Error("quota"); this.values.set(key, value); }
  removeItem(key: string) { if (this.failRemove) throw new Error("blocked"); this.values.delete(key); }
}

const record: ScoreRecord = { id: "11111111-1111-4111-8111-111111111111", songId: "cono-home-stage-v1", title: "우리 집 무대", artist: "CoNo", source: "browser", difficulty: "normal", keyShift: 0, score: 90, notesHit: 23, notesTotal: 26, bestStreak: 10, createdAt: "2026-10-01T12:00:00.000Z" };

test("failed score saves survive reload and independent tabs retain both records", () => {
  const storage = new MemoryStorage();
  const tabA = new PendingScoreStore(() => storage), tabB = new PendingScoreStore(() => storage);
  const other = { ...record, id: "22222222-2222-4222-8222-222222222222" };
  assert.equal(tabA.remember(record), "");
  assert.equal(tabB.remember(other), "");
  const reloaded = new PendingScoreStore(() => storage);
  assert.deepEqual(new Set(reloaded.read().records.map(({ id }) => id)), new Set([record.id, other.id]));
  assert.equal(reloaded.forget(record.id), "");
  assert.deepEqual(tabB.read().records.map(({ id }) => id), [other.id]);
});

test("full or unavailable local storage keeps the new score in memory for JSON export", () => {
  const storage = new MemoryStorage();
  storage.failWrite = true;
  const pending = new PendingScoreStore(() => storage);
  assert.match(pending.remember(record), /JSON/);
  assert.deepEqual(pending.read().records, [record]);
  assert.match(pending.read().warning, /새로고침/);
  storage.failWrite = false;
  assert.equal(pending.remember(record), "");
  assert.equal(pending.read().warning, "");
  assert.deepEqual(new PendingScoreStore(() => storage).read().records, [record]);
  const blocked = new PendingScoreStore(() => { throw new Error("blocked"); });
  assert.match(blocked.remember(record), /JSON/);
  assert.deepEqual(blocked.read().records, [record]);
});

test("malformed pending records are preserved and do not hide intact scores", () => {
  const storage = new MemoryStorage();
  storage.setItem(PENDING_SCORE_PREFIX + "broken", "{unfinished");
  const pending = new PendingScoreStore(() => storage);
  pending.remember(record);
  assert.deepEqual(pending.read().records, [record]);
  assert.match(pending.read().warning, /원본/);
  assert.equal(storage.getItem(PENDING_SCORE_PREFIX + "broken"), "{unfinished");
  assert.match(pending.remember({ ...record, score: 80 }), /JSON/);
  assert.equal(JSON.parse(storage.getItem(PENDING_SCORE_PREFIX + record.id)!).score, 90);
});

test("failed removal retains the pending record until deletion succeeds", () => {
  const storage = new MemoryStorage();
  const pending = new PendingScoreStore(() => storage);
  pending.remember(record);
  storage.failRemove = true;
  assert.match(pending.forget(record.id), /다시/);
  assert.deepEqual(pending.read().records, [record]);
  storage.failRemove = false;
  assert.equal(pending.forget(record.id), "");
  assert.deepEqual(pending.read().records, []);
});
