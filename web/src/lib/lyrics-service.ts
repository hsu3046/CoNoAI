// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { byteLength, LyricsError, MAX_LIBRARY_BYTES, parseLyricsInput, type LyricsRecord } from "./lyrics-record.ts";
import type { LyricsData } from "./lyrics-repository.ts";
import { object, UUID } from "./score-record.ts";

export function ownedLyrics(data: LyricsData, ownerId: string, id: unknown, version?: unknown): LyricsRecord {
  const record = data.lyrics.find((item) => item.ownerId === ownerId && item.record.id === id)?.record;
  if (!record) throw new LyricsError("가사를 찾지 못했어요. 이 브라우저의 보관함을 새로고침해 주세요.", 404);
  if (version !== undefined && record.version !== version) throw new LyricsError("다른 탭에서 이 가사를 수정했어요. 입력 내용은 유지됩니다. 현재 초안을 내보내고 최신 저장본을 다시 열어 주세요.", 409);
  return record;
}

/** read→검증→쓰기 전체를 Repository의 잠금 안에서 실행한다. */
export function changeLyrics(data: LyricsData, ownerId: string, value: unknown): LyricsRecord | null {
  let body: Record<string, unknown>;
  try { body = object(value); } catch { throw new LyricsError("요청 형식을 확인해 주세요."); }
  if (typeof body.id !== "string" || !UUID.test(body.id)) throw new LyricsError("가사 ID를 확인해 주세요.");
  const id = body.id.toLowerCase();
  if (body.action === "delete") {
    if (!Number.isSafeInteger(body.version)) throw new LyricsError("삭제할 가사의 버전을 확인해 주세요.");
    ownedLyrics(data, ownerId, id, body.version);
    data.lyrics = data.lyrics.filter((item) => item.record.id !== id);
    return null;
  }
  if (body.action !== "create" && body.action !== "update") throw new LyricsError("지원하지 않는 요청이에요.");
  const input = parseLyricsInput(body.lyrics);
  const previous = data.lyrics.find((item) => item.record.id === id);
  if (body.action === "create" && previous) {
    // 응답을 놓친 재시도만 같은 레코드로 회복하며 다른 소유자·다른 내용은 덮어쓰지 않는다.
    if (previous.ownerId === ownerId && JSON.stringify(parseLyricsInput(previous.record)) === JSON.stringify(input)) return previous.record;
    throw new LyricsError("같은 ID의 다른 가사가 있어요. 새 가사로 등록해 주세요.", 409);
  }
  const now = new Date().toISOString();
  let record: LyricsRecord;
  if (body.action === "update") {
    if (!Number.isSafeInteger(body.version)) throw new LyricsError("편집한 가사의 버전을 확인해 주세요.");
    const original = ownedLyrics(data, ownerId, id, body.version);
    if (original.version >= Number.MAX_SAFE_INTEGER) throw new LyricsError("새 가사로 등록해 주세요.");
    record = { ...input, id, version: original.version + 1, createdAt: original.createdAt, updatedAt: now };
  } else record = { ...input, id, version: 1, createdAt: now, updatedAt: now };
  const mine = data.lyrics.filter((item) => item.ownerId === ownerId && item.record.id !== id).map((item) => item.record);
  if (mine.length >= 200 || byteLength(JSON.stringify([...mine, record])) > MAX_LIBRARY_BYTES) throw new LyricsError("개인 보관함은 200곡·8 MB까지 저장할 수 있어요. TXT/LRC로 백업한 뒤 정리해 주세요.");
  if (previous) previous.record = record;
  else data.lyrics.push({ ownerId, record });
  return record;
}
