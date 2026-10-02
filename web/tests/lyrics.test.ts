// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import test from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { decodeLyricsFile, exportLyrics, lyricsLines, LyricsError, MAX_LYRICS_BYTES, parseLyricsInput, parseLyricsRecord } from "../src/lib/lyrics-record.ts";
import { LyricsRepository, lyricsRepository } from "../src/lib/lyrics-repository.ts";
import { changeLyrics, ownedLyrics } from "../src/lib/lyrics-service.ts";
import { LRCLIBPublishBackoff, parseChallenge, publishPayload, requestPublishChallenge, sendPublication, solvePublishChallenge, UNCERTAIN_PUBLICATION } from "../src/lib/lrclib-publish.ts";

const input = { title: "나의 노래", artist: "가수", album: "", duration: null, format: "plain" as const, content: "첫 번째 줄\n두 번째 줄" };
const create = (id = randomUUID(), lyrics = input) => ({ action: "create", id, lyrics });
test("lyrics: TXT/LRC, offset, repeated times and enhanced source survive file exchange", () => {
  const lrc = "[ti:노래]\n[offset:500]\n[00:01.000][00:03.000] <00:01.000>첫 줄<00:02.000>\n[00:04.000] 다음 줄\n";
  assert.deepEqual(lyricsLines(lrc, "lrc"), [{ text: "첫 줄", time: 0.5 }, { text: "첫 줄", time: 2.5 }, { text: "다음 줄", time: 3.5 }]);
  assert.deepEqual(lyricsLines("[offset: +500 ]\n[ 00:0.2 ] < 00:0.2 >앞 줄<00:01>\n[00:02] 다음", "lrc"), [{ text: "앞 줄", time: 0 }, { text: "다음", time: 1.5 }]);
  const record = { ...input, format: "lrc" as const, content: lrc };
  assert.equal(exportLyrics(record, "lrc"), lrc);
  assert.equal(exportLyrics(record, "plain"), "첫 줄\n첫 줄\n다음 줄\n");
  assert.throws(() => exportLyrics(input, "lrc"), /시각이 없어요/);
  for (const content of ["\nfirst verse\n\nsecond verse\n", "\n\n첫 절\n\n후렴\n\n", "no trailing newline"]) assert.equal(exportLyrics({ ...input, content }, "plain"), content, "TXT backups keep leading, interior and trailing blank lines");
  const bytes = Buffer.from("\ufeff첫 번째 줄\r\n두 번째 줄", "utf16le");
  assert.deepEqual(decodeLyricsFile(Uint8Array.from(bytes).buffer, "lyrics.TXT"), { content: "첫 번째 줄\r\n두 번째 줄", format: "plain" });
  assert.throws(() => decodeLyricsFile(Uint8Array.from([255, 0, 255]).buffer, "bad.txt"), /UTF-8/);
  assert.throws(() => decodeLyricsFile(new ArrayBuffer(0), "song.exe"), /TXT 또는 LRC/);
});
test("lyrics: metadata, raw UTF-8 bytes, line count, line length and malformed timing are bounded", () => {
  assert.equal(parseLyricsInput({ ...input, title: " 제목 ", content: "가\r\n나\u2028다" }).content, "가\n나\n다");
  for (const patch of [{ title: " " }, { artist: "" }, { album: "가".repeat(201) }, { duration: 0 }, { duration: Infinity }, { format: "html" }, { content: "\0abc" }, { content: "가".repeat(501) }, { content: "a\n".repeat(4001) }, { content: "" }]) assert.throws(() => parseLyricsInput({ ...input, ...patch }), LyricsError);
  assert.throws(() => lyricsLines("가".repeat(Math.floor(MAX_LYRICS_BYTES / 3) + 1), "plain"), /1 MB/);
  for (const content of ["[00:61] 가사", "[01:00] 가사\n시간 없는 줄", "[offset:-2000]\n[1440:00] 가사", "[00:01] <00:99>가사", "[offset:Infinity]\n[00:01] 가사"]) assert.throws(() => lyricsLines(content, "lrc"), LyricsError);
  assert.deepEqual(lyricsLines("[00:01] [후렴]", "lrc"), [{ time: 1, text: "[후렴]" }]);
});
test("lyrics: private owners, idempotent create, optimistic edit/delete and input failure are atomic", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "cono-lyrics-test-"));
  const repository = new LyricsRepository(directory), owner = randomUUID(), other = randomUUID(), id = randomUUID();
  try {
    const first = await repository.update((data) => changeLyrics(data, owner, create(id)));
    assert.ok(first); assert.equal(parseLyricsRecord(first).version, 1);
    assert.equal((await repository.update((data) => changeLyrics(data, owner, create(id))))?.version, 1);
    await assert.rejects(repository.update((data) => changeLyrics(data, other, create(id))), /같은 ID/);
    assert.throws(() => ownedLyrics({ schemaVersion: 1, lyrics: [{ ownerId: owner, record: first }] }, other, id), /찾지 못했어요/);
    for (const value of [null, [], { action: "create", id }, { action: "delete", id }, { action: "update", id, lyrics: input }]) await assert.rejects(repository.update((data) => changeLyrics(data, owner, value)));
    const updated = await repository.update((data) => changeLyrics(data, owner, { action: "update", id, version: 1, lyrics: { ...input, content: "수정한 가사" } }));
    assert.equal(updated?.version, 2);
    await assert.rejects(repository.update((data) => changeLyrics(data, owner, { action: "update", id, version: 1, lyrics: input })), /다른 탭/);
    await assert.rejects(repository.update((data) => changeLyrics(data, owner, { action: "delete", id, version: 1 })), /다른 탭/);
    await assert.rejects(repository.update((data) => changeLyrics(data, other, { action: "delete", id, version: 2 })), /찾지 못했어요/);
    assert.equal((await repository.read()).lyrics[0].record.content, "수정한 가사");
    await repository.update((data) => changeLyrics(data, owner, { action: "delete", id, version: 2 }));
    assert.deepEqual((await repository.read()).lyrics, []);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test("lyrics: concurrent writes retain every record and corrupt files are never reset", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "cono-lyrics-test-"));
  const repository = new LyricsRepository(directory), owner = randomUUID();
  try {
    await Promise.all(Array.from({ length: 12 }, () => repository.update((data) => changeLyrics(data, owner, create()))));
    assert.equal((await repository.read()).lyrics.length, 12);
    const file = path.join(directory, "store.json");
    await writeFile(file, "{broken");
    await assert.rejects(repository.update((data) => changeLyrics(data, owner, create())), /원본은 보존/);
    assert.equal(await readFile(file, "utf8"), "{broken");
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test("lyrics: deployment without a durable repository remains unavailable", () => {
  const previous = process.env.VERCEL;
  try { process.env.VERCEL = "1"; assert.throws(() => lyricsRepository(), /로컬 테스트/); }
  finally { if (previous === undefined) delete process.env.VERCEL; else process.env.VERCEL = previous; }
});
test("lyrics: full libraries still allow revision-safe edits and refuse extra records atomically", () => {
  const ownerId = randomUUID(), now = new Date().toISOString();
  const data = { schemaVersion: 1 as const, lyrics: Array.from({ length: 200 }, () => ({ ownerId, record: { ...input, id: randomUUID(), version: 1, createdAt: now, updatedAt: now } })) };
  assert.throws(() => changeLyrics(data, ownerId, create()), /200곡/);
  assert.equal(data.lyrics.length, 200);
  const first = data.lyrics[0].record;
  assert.equal(changeLyrics(data, ownerId, { action: "update", id: first.id, version: 1, lyrics: { ...input, title: "수정" } })?.version, 2);
  assert.equal(data.lyrics.length, 200);
});
test("LRCLIB: plain-only and canonical line timing match the reviewed payload", () => {
  assert.throws(() => publishPayload(input), /실제 곡 길이/);
  assert.deepEqual(publishPayload({ ...input, duration: 120.5 }), { trackName: input.title, artistName: input.artist, albumName: "", duration: 120.5, plainLyrics: input.content, syncedLyrics: "" });
  const timed = { ...input, duration: 10, format: "lrc" as const, content: "[offset:500]\n[00:01] <00:01>첫 줄<00:02>\n[00:05] 끝" };
  assert.equal(publishPayload(timed).syncedLyrics, "[00:00.500] 첫 줄\n[00:04.500] 끝");
  assert.throws(() => publishPayload({ ...timed, duration: 4.5 }), /곡 길이보다/);
  const cue = publishPayload({ ...input, duration: 60, format: "lrc", content: "[00:01] opening\n[00:05]\n[00:40] verse" });
  assert.equal(cue.plainLyrics, "opening\nverse");
  assert.equal(cue.syncedLyrics, "[00:01.000] opening\n[00:05.000] \n[00:40.000] verse", "Instrumental stop cues must remain in the public timed lyrics");
  assert.equal(publishPayload({ ...input, duration: 10, format: "lrc", content: "[00:01] verse\n[00:10]" }).syncedLyrics, "[00:01.000] verse\n[00:10.000] ");
});
test("LRCLIB: challenge format, SHA256 rule, attempt/time limits and cancellation", async () => {
  const challenge = { prefix: "prefix", target: "f".repeat(64) };
  assert.equal(await solvePublishChallenge(challenge), "prefix:0");
  const digest = createHash("sha256").update("prefix0").digest("hex");
  assert.equal(await solvePublishChallenge({ prefix: "prefix", target: digest }), "prefix:0", "Equality satisfies the official <= comparison");
  for (const value of [{ prefix: "", target: challenge.target }, { ...challenge, target: "0".repeat(64) }, { ...challenge, target: "x".repeat(64) }]) assert.throws(() => parseChallenge(value), /인증 응답/);
  let calls = 0;
  await assert.rejects(solvePublishChallenge({ prefix: "p", target: "1".repeat(64) }, { maximumAttempts: 3, hash: async () => { calls++; return "f".repeat(64); } }), /계산이 오래/);
  assert.equal(calls, 3);
  await assert.rejects(solvePublishChallenge(challenge, { timeoutMs: 0 }), /계산이 오래/);
  let cancelled = false;
  await assert.rejects(solvePublishChallenge(challenge, { hash: async () => { cancelled = true; return "0".repeat(64); }, checkCancelled: () => { if (cancelled) throw new DOMException("Cancelled", "AbortError"); } }), { name: "AbortError" });
});
test("LRCLIB: stub-only transport checks status, response cap, preflight cancellation and uncertain POST", async () => {
  const controller = new AbortController();
  const challenge = { prefix: "abc", target: "f".repeat(64) };
  const calls: { url: string; init?: RequestInit }[] = [];
  const transport: typeof fetch = async (url, init) => { calls.push({ url: String(url), init }); return Response.json(challenge); };
  assert.deepEqual(await requestPublishChallenge(controller.signal, transport), challenge);
  assert.equal(calls[0].url, "https://lrclib.net/api/request-challenge"); assert.equal(calls[0].init?.method, "POST");
  await assert.rejects(requestPublishChallenge(controller.signal, async () => new Response("x".repeat(4097))), /4 KB/);
  await assert.rejects(requestPublishChallenge(controller.signal, async () => new Response("{}", { status: 429 }), new LRCLIBPublishBackoff()), /요청 제한/);
  await assert.rejects(requestPublishChallenge(controller.signal, async () => { throw new TypeError("network"); }), /LRCLIB에 연결하지 못했어요/);
  const payload = publishPayload({ ...input, duration: 120 });
  await sendPublication(payload, "abc:0", controller.signal, async (url, init) => {
    assert.equal(String(url), "https://lrclib.net/api/publish");
    assert.equal(new Headers(init?.headers).get("X-Publish-Token"), "abc:0");
    assert.deepEqual(JSON.parse(String(init?.body)), payload);
    return new Response(null, { status: 201 });
  });
  await assert.rejects(sendPublication(payload, "abc:0", controller.signal, async () => { throw new TypeError("network"); }), { message: UNCERTAIN_PUBLICATION });
  await assert.rejects(sendPublication(payload, "abc:0", controller.signal, async () => new Response(null, { status: 400 })), /HTTP 400/);
  controller.abort();
  await assert.rejects(sendPublication(payload, "abc:0", controller.signal, async () => { assert.fail("No POST after cancellation"); }), { name: "AbortError" });
  assert.equal(calls.length, 1);
});
test("LRCLIB: Retry-After seconds/date blocks both endpoints without another transport call", async () => {
  let now = 1_700_000_000_000, calls = 0;
  const backoff = new LRCLIBPublishBackoff(() => now), signal = new AbortController().signal;
  const payload = publishPayload({ ...input, duration: 120 });
  const limited: typeof fetch = async () => { calls++; return new Response(null, { status: 429, headers: { "Retry-After": "120" } }); };
  await assert.rejects(requestPublishChallenge(signal, limited, backoff), (error: unknown) => error instanceof LyricsError && error.status === 429 && error.retryAfterSeconds === 120);
  await assert.rejects(requestPublishChallenge(signal, limited, backoff), /120초/);
  await assert.rejects(sendPublication(payload, "abc:0", signal, limited, backoff), /120초/);
  assert.equal(calls, 1);
  now += 120_000;
  const dateLimited: typeof fetch = async () => { calls++; return new Response(null, { status: 429, headers: { "Retry-After": new Date(now + 90_000).toUTCString() } }); };
  await assert.rejects(sendPublication(payload, "abc:0", signal, dateLimited, backoff), /90초/);
  await assert.rejects(requestPublishChallenge(signal, limited, backoff), /90초/);
  assert.equal(calls, 2);
  now += 90_000;
  await requestPublishChallenge(signal, async () => { calls++; return Response.json({ prefix: "abc", target: "f".repeat(64) }); }, backoff);
  assert.equal(calls, 3);
});
