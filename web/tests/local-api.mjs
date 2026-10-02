// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 실행 중인 로컬 서버만 검증. 무작위 ID의 테스트 기록만 만든 뒤 정리한다.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const origin = process.env.CONO_TEST_URL || 'http://127.0.0.1:3100';
if (!['localhost', '127.0.0.1', '[::1]'].includes(new URL(origin).hostname)) throw new Error('Local server only');
function client() {
  let cookie = '';
  return async (route, body, expected = 200, extraHeaders = {}) => {
    const response = await fetch(`${origin}${route}`, { method: body === undefined ? 'GET' : 'POST', headers: { Cookie: cookie, ...(body === undefined ? {} : { 'Content-Type': 'application/json', Origin: origin }), ...extraHeaders }, body: body === undefined ? undefined : JSON.stringify(body) });
    const set = response.headers.get('set-cookie');
    if (set) cookie = set.split(';')[0];
    const text = await response.text();
    assert.equal(response.status, expected, `${route}: ${text.slice(0,200)}`);
    return response.headers.get('content-type')?.includes('json') ? JSON.parse(text) : text;
  };
}
const a = client(), b = client(), large = client();
const songId = `test-${randomUUID()}`;
const base = { id: randomUUID(), songId, title: '통합 테스트 무대', artist: '테스트', source: 'browser', difficulty: 'normal', keyShift: 0, score: 92, notesHit: 23, notesTotal: 26, bestStreak: 12, createdAt: new Date().toISOString() };
const second = { ...base, id: randomUUID(), score: 95 };
const other = { ...base, id: randomUUID() };
let restoredId;
const hard = { ...base, id: randomUUID(), difficulty: 'hard' };
const largeRecords = [];
let largeSaved = false;
try {
  assert.deepEqual((await a('/api/scores')).records, []);
  assert.deepEqual((await b('/api/scores')).records, []);
  await a('/api/scores', null, 400);
  await a('/api/scores', { action: 'save', record: { ...base, score: -1 } }, 400);
  await a('/api/scores', { action: 'save', record: { ...base, createdAt: '2026-10-02T12:00:00' } }, 400);
  await a('/api/scores', { action: 'save', record: base }, 403, { Origin: 'https://example.invalid' });
  await a('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [base, { ...second, notesHit: 100 }] } }, 400);
  assert.equal((await a('/api/scores')).records.length, 0);
  await a('/api/scores', { action: 'save', record: base });
  await a('/api/scores', { action: 'save', record: base });
  assert.equal((await a('/api/scores')).records.length, 1);
  await a('/api/scores', { action: 'save', record: { ...base, score: 99 } }, 409);
  await b('/api/scores', { action: 'save', record: base }, 409);
  await b('/api/scores', { action: 'delete', id: base.id }, 404);
  assert.equal((await b('/api/scores')).records.length, 0);
  await b('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [base] } });
  restoredId = (await b('/api/scores')).records[0].id;
  assert.notEqual(restoredId, base.id);
  await b('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [base] } });
  assert.equal((await b('/api/scores')).records.length, 1);
  await a('/api/scores', { action: 'delete', id: base.id });
  await b('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [base] } });
  assert.equal((await b('/api/scores')).records.length, 1, 'Deleting the original must not duplicate an existing restored copy');
  await b('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [{ ...base, score: 80 }] } }, 409);
  assert.ok(!(await a('/api/challenges')).entries.some((v) => v.record.songId === songId));
  await a('/api/scores', { action: 'profile', nickname: '가왕 A' });
  for (const record of [base, second, hard]) {
    await a('/api/scores', { action: 'save', record });
    await a('/api/scores', { action: 'publish', id: record.id, published: true });
  }
  await b('/api/scores', { action: 'save', record: other });
  await b('/api/scores', { action: 'publish', id: other.id, published: true });
  const rows = (await a('/api/challenges')).entries.filter((v) => v.record.songId === songId);
  assert.equal(rows.length, 3); // 본인 최고 한 건 + 다른 가수 + 별도 난이도
  assert.equal(rows[0].record.score, 95);
  const html = await a(`/scores/${second.id}`);
  assert.match(html, /가왕 A/);
  assert.match(html, /통합 테스트 무대/);
  await a('/api/scores', { action: 'publish', id: second.id, published: false });
  const hidden = await fetch(`${origin}/scores/${second.id}`);
  assert.match(await hidden.text(), /공유된 기록을 찾지 못했어요/);
  const fallback = (await a('/api/challenges')).entries.filter((v) => v.record.songId === songId && v.nickname === '가왕 A' && v.record.difficulty === 'normal');
  assert.equal(fallback[0].record.id, base.id);
  await a('/api/feedback', null, 400);
  await a('/api/feedback', { message: 'test', email: 'invalid' }, 400);
  await a('/api/feedback', { mood: 5, message: '로컬 API 통합 테스트 의견', email: '' });
  // 950 KB 이상의 유효한 백업 및 1 MB를 넘는 전송 래퍼를 실제 API로 왕복한다.
  for (let i = 0; i < 1000; i++) {
    const next = { ...base, id: randomUUID(), songId: '가'.repeat(500), title: '나'.repeat(200), artist: '다'.repeat(200) };
    if (Buffer.byteLength(JSON.stringify({ schemaVersion: 1, records: [...largeRecords, next] })) > 1_048_576) break;
    largeRecords.push(next);
  }
  const document = { schemaVersion: 1, records: largeRecords };
  assert.ok(Buffer.byteLength(JSON.stringify(document)) > 950_000);
  const envelope = { action: 'import', document, transportPadding: ' '.repeat(4096) };
  assert.ok(Buffer.byteLength(JSON.stringify(envelope)) > 1_048_576);
  await large('/api/scores');
  await large('/api/scores', envelope);
  largeSaved = true;
  assert.equal((await large('/api/scores')).records.length, largeRecords.length);
  await large('/api/scores', { action: 'import', document: { schemaVersion: 1, records: [...largeRecords, { ...largeRecords[0], id: randomUUID() }] } }, 400);
  assert.equal((await large('/api/scores')).records.length, largeRecords.length, 'Oversized import must remain atomic');
  console.log('PASS: timezone, 1 MB archive/envelope, ownership, restore after deletion, atomic import, grouped best score, publish/revoke, feedback');
} finally {
  for (const id of [base.id, second.id, hard.id]) await a('/api/scores', { action: 'delete', id }).catch(() => {});
  await b('/api/scores', { action: 'delete', id: other.id }).catch(() => {});
  if (restoredId) await b('/api/scores', { action: 'delete', id: restoredId });
  for (let start = 0; largeSaved && start < largeRecords.length; start += 6) {
    await Promise.all(largeRecords.slice(start, start + 6).map(({ id }) => large('/api/scores', { action: 'delete', id })));
  }
}
