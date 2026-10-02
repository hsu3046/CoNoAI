// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 앱과 웹이 교환하는 버전 있는 JSON. 녹음·음정 프레임은 포함하지 않는다.
export type ScoreRecord = {
  id: string; songId: string; title: string; artist: string;
  source: "macos" | "browser" | "demo";
  difficulty: "normal" | "hard";
  keyShift: number; score: number; notesHit: number; notesTotal: number; bestStreak: number; createdAt: string;
};
export type ScoreDocument = { schemaVersion: 1; records: ScoreRecord[] };
export const MAX_ARCHIVE_BYTES = 1_048_576;
export const PRACTICE_SONG = "cono-home-stage-v1";
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("JSON 형식을 확인해 주세요.");
  return value as Record<string, unknown>;
}
function text(value: unknown, limit: number, allowEmpty = false): string {
  if (typeof value !== "string" || value.length > limit || (!allowEmpty && !value.trim())) throw new Error("곡 정보가 올바르지 않아요.");
  return value.trim();
}
function integer(value: unknown, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) throw new Error("점수 값이 올바르지 않아요.");
  return value;
}
export function parseRecord(value: unknown): ScoreRecord {
  const v = object(value);
  const id = text(v.id, 36).toLowerCase();
  if (!UUID.test(id)) throw new Error("기록 ID가 올바르지 않아요.");
  const source = v.source;
  const difficulty = v.difficulty;
  if (source !== "macos" && source !== "browser" && source !== "demo") throw new Error("알 수 없는 채점 방식이에요.");
  if (difficulty !== "normal" && difficulty !== "hard") throw new Error("난이도를 확인해 주세요.");
  const createdAt = text(v.createdAt, 40);
  const timestamp = Date.parse(createdAt);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(createdAt) || !Number.isFinite(timestamp) || timestamp < Date.UTC(2020, 0, 1) || timestamp > Date.now() + 300_000) throw new Error("기록 날짜에 시간대(Z 또는 +09:00)를 포함해 주세요.");
  const notesTotal = integer(v.notesTotal, 1, 50_000);
  const notesHit = integer(v.notesHit, 0, notesTotal);
  return { id, source, difficulty, createdAt: new Date(timestamp).toISOString(),
    songId: text(v.songId, 500), title: text(v.title, 200), artist: text(v.artist, 200, true),
    keyShift: integer(v.keyShift, -6, 6), score: integer(v.score, 0, 100), notesTotal, notesHit,
    bestStreak: integer(v.bestStreak, 0, notesHit) };
}
export function parseDocument(value: unknown): ScoreDocument {
  const v = object(value);
  if (v.schemaVersion !== 1 || !Array.isArray(v.records) || v.records.length > 1000) throw new Error("CoNo 점수 JSON v1(최대 1,000곡)이 필요해요.");
  const records = v.records.map(parseRecord);
  if (new Set(records.map((record) => record.id)).size !== records.length) throw new Error("파일 안에 중복 기록이 있어요.");
  const document: ScoreDocument = { schemaVersion: 1, records };
  if (new TextEncoder().encode(JSON.stringify(document)).byteLength > MAX_ARCHIVE_BYTES) throw new Error("기록은 1 MB까지 저장할 수 있어요. JSON으로 백업한 뒤 정리해 주세요.");
  return document;
}
/** 두 플랫폼 모두 공백을 덧붙이지 않는 UTF-8 JSON으로 같은 1 MB 한도를 적용한다. */
export function serializeDocument(records: ScoreRecord[]): string {
  return JSON.stringify(parseDocument({ schemaVersion: 1, records }));
}
/** 한국 시간 월요일 00:00을 기준으로 같은 주·곡·방식·난이도만 비교한다. */
export function weekKey(date: Date): string {
  const seoul = new Date(date.getTime() + 9 * 3_600_000);
  seoul.setUTCDate(seoul.getUTCDate() - (seoul.getUTCDay() + 6) % 7);
  return seoul.toISOString().slice(0, 10);
}
export function groupKey(record: ScoreRecord): string { return JSON.stringify([record.songId, record.source, record.difficulty]); }
export function scoreText(record: ScoreRecord): string {
  return `🎤 CoNo · ${record.title}${record.artist ? ` — ${record.artist}` : ""}\n${record.score}점 · 음표 ${record.notesHit}/${record.notesTotal} · 최고 연속 ${record.bestStreak}\n${record.source === "macos" ? "Mac" : record.source === "demo" ? "데모" : "브라우저"} · ${record.difficulty === "hard" ? "어려움" : "보통"}`;
}
