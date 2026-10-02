// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 로컬 개인 보관함만 검사한다. LRCLIB POST는 호출하지 않는다.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
const origin = process.env.CONO_TEST_URL || "http://127.0.0.1:3100";
if (!["localhost", "127.0.0.1", "[::1]"].includes(new URL(origin).hostname)) throw new Error("Local server only");
function client() {
  let cookie = "";
  return async (body, expected = 200, extra = {}, route = "/api/lyrics") => {
    const response = await fetch(`${origin}${route}`, { method: body === undefined ? "GET" : "POST", headers: { Cookie: cookie, ...(body === undefined ? {} : { "Content-Type": "application/json", Origin: origin }), ...extra }, body: body === undefined ? undefined : JSON.stringify(body) });
    const set = response.headers.get("set-cookie"); if (set) cookie = set.split(";")[0];
    const text = await response.text(); assert.equal(response.status, expected, text.slice(0, 300));
    return JSON.parse(text);
  };
}
const a = client(), b = client(), id = randomUUID();
const lyrics = { title: "개인 가사 API 테스트", artist: "CoNo", album: "", duration: null, format: "plain", content: "내가 적은 첫 줄\n다음 줄" };
let version = 1;
try {
  assert.deepEqual((await a()).records, []); assert.deepEqual((await b()).records, []);
  await a(null, 400);
  await a({ action: "create", id, lyrics: { ...lyrics, artist: "" } }, 400);
  await a({ action: "create", id, lyrics: { ...lyrics, content: "가".repeat(350_000) } }, 400);
  await a({ action: "create", id, lyrics }, 403, { Origin: "https://example.invalid" });
  assert.equal((await a({ action: "create", id, lyrics })).record.version, 1);
  assert.equal((await a({ action: "create", id, lyrics })).record.version, 1);
  assert.deepEqual((await b()).records, []);
  // 모든 공개 검사는 외부 전송 전 실패하는 요청만 사용한다.
  await a({ action: "challenge", id, version, consent: false }, 400, {}, "/api/lyrics/publish");
  await b({ action: "challenge", id, version, consent: true }, 404, {}, "/api/lyrics/publish");
  await a({ action: "challenge", id, version, consent: true }, 400, {}, "/api/lyrics/publish"); // 실제 길이 미입력
  await b({ action: "update", id, version, lyrics }, 404);
  await b({ action: "delete", id, version }, 404);
  await a({ action: "update", id, version, lyrics: { ...lyrics, format: "lrc", duration: 30, content: "[00:01] 첫 줄\n[00:10] 다음 줄" } }); version = 2;
  await a({ action: "update", id, version: 1, lyrics }, 409);
  await a({ action: "delete", id, version: 1 }, 409);
  const stored = (await a()).records[0]; assert.equal(stored.version, 2); assert.equal(stored.format, "lrc");
  const html = await (await fetch(`${origin}/lyrics`)).text(); assert.match(html, /노래할 가사/);
  console.log("PASS: lyrics ownership, input/size/origin validation, idempotency, stale update/delete, private LRC roundtrip, publish preflight rejection, page");
} finally { await a({ action: "delete", id, version }).catch(() => {}); }
