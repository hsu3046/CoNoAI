// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { object, UUID } from "./score-record.ts";

export const MAX_LYRICS_BYTES = 1_048_576;
export const MAX_LIBRARY_BYTES = 8 * MAX_LYRICS_BYTES;
export type LyricsFormat = "plain" | "lrc";
export type LyricsInput = { title: string; artist: string; album: string; duration: number | null; format: LyricsFormat; content: string };
export type LyricsRecord = LyricsInput & { id: string; version: number; createdAt: string; updatedAt: string };
export type LyricsLine = { text: string; time: number | null };
export class LyricsError extends Error {
  readonly status: number;
  readonly retryAfterSeconds?: number;
  constructor(message: string, status = 400, retryAfterSeconds?: number) { super(message); this.status = status; this.retryAfterSeconds = retryAfterSeconds; }
}
export function byteLength(text: string): number { return new TextEncoder().encode(text).byteLength; }

function timestamp(text: string): number | null {
  const match = /^(\d{1,4})\s*:\s*(\d{1,2})(?:[.:](\d{1,9}))?$/.exec(text.trim());
  if (!match) return null;
  if (Number(match[2]) >= 60) return null;
  const value = Number(match[1]) * 60 + Number(match[2]) + (match[3] ? Number(`0.${match[3]}`) : 0);
  return value <= 86_400 ? value : null;
}

/** LRC 원문은 그대로 저장하고, 미리보기·TXT·게시에는 검증한 시각/본문만 사용한다. */
export function lyricsLines(content: string, format: LyricsFormat): LyricsLine[] {
  if (byteLength(content) > MAX_LYRICS_BYTES) throw new LyricsError("가사 파일은 UTF-8 기준 1 MB까지 저장할 수 있어요.");
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(content)) throw new LyricsError("가사에 읽을 수 없는 제어 문자가 있어요. 텍스트 파일을 확인해 주세요.");
  const rows = content.replace(/^\uFEFF/, "").split(/\r\n|[\n\r\u0085\u2028\u2029]/);
  if (rows.length > 4_001 || (rows.length === 4_001 && rows.at(-1) !== "")) throw new LyricsError("가사는 4,000줄까지 저장할 수 있어요.");
  const result: LyricsLine[] = [];
  let offset = 0;
  for (const [index, raw] of rows.entries()) {
    const row = raw.trim();
    if (!row) continue;
    if (format === "plain") {
      if (Array.from(raw).length > 500) throw new LyricsError(`${index + 1}번째 줄은 500글자 이하여야 해요.`);
      result.push({ text: raw, time: null });
      continue;
    }
    const metadata = /^\[(ar|ti|al|by|re|ve|length|offset):([^\]]*)\]$/i.exec(row);
    if (metadata) {
      if (metadata[1].toLowerCase() === "offset") {
        if (!/^[+-]?\d+(?:\.\d+)?$/.test(metadata[2].trim()) || Math.abs(Number(metadata[2])) > 120_000) throw new LyricsError("LRC 오프셋은 ±120,000밀리초까지 사용할 수 있어요.");
        offset = Number(metadata[2]) / 1000;
      }
      continue;
    }
    const times: number[] = [];
    let rest = row;
    while (rest.startsWith("[")) {
      const end = rest.indexOf("]");
      if (end < 0) break;
      const time = timestamp(rest.slice(1, end));
      if (time === null) break;
      times.push(time); rest = rest.slice(end + 1);
    }
    if (!times.length) throw new LyricsError(`${index + 1}번째 줄에 [00:00.000] 형식의 시각이 필요해요. 일반 가사는 TXT를 선택해 주세요.`);
    // 원본 단어 시각은 LRC 내보내기에 보존한다. 잘못된 시간 모양의 태그는 조용히 제거하지 않는다.
    rest = rest.replace(/<([^<>]+)>/g, (tag, value: string) => {
      if (timestamp(value) !== null) return "";
      if (/^\d.*:/.test(value.trim())) throw new LyricsError(`${index + 1}번째 줄의 단어 시각을 확인해 주세요.`);
      return tag;
    }).trim();
    if (Array.from(rest).length > 500) throw new LyricsError(`${index + 1}번째 줄은 500글자 이하여야 해요.`);
    for (const time of times) result.push({ text: rest, time });
    if (result.length > 4_000) throw new LyricsError("시각을 펼친 가사는 4,000줄까지 저장할 수 있어요.");
  }
  if (!result.some((line) => line.text.trim())) throw new LyricsError("가사 내용을 입력해 주세요.");
  if (format === "lrc") {
    for (const line of result) {
      // LRC 관례와 Mac 파서: 양수 offset은 가사를 앞당기며 0초보다 이른 시각은 0초로 제한한다.
      line.time = Math.max(0, (line.time ?? 0) - offset);
      if (line.time > 86_400) throw new LyricsError("오프셋을 적용한 가사 시각은 0~86,400초 안이어야 해요.");
    }
    result.sort((a, b) => (a.time ?? 0) - (b.time ?? 0));
  }
  return result;
}

export function parseLyricsInput(value: unknown): LyricsInput {
  let item: Record<string, unknown>;
  try { item = object(value); } catch { throw new LyricsError("가사 입력 형식을 확인해 주세요."); }
  const field = (key: string, required: boolean) => {
    const value = item[key];
    if (typeof value !== "string" || value.trim().length > 200 || (required && !value.trim())) throw new LyricsError("제목과 가수는 필수이며 제목·가수·앨범은 각각 200자까지 입력할 수 있어요.");
    return value.trim();
  };
  const title = field("title", true), artist = field("artist", true), album = field("album", false);
  if (item.duration !== null && (typeof item.duration !== "number" || !Number.isFinite(item.duration) || item.duration <= 0 || item.duration > 86_400)) throw new LyricsError("곡 길이는 비워 두거나 0초보다 크고 86,400초 이하로 입력해 주세요.");
  if (item.format !== "plain" && item.format !== "lrc") throw new LyricsError("TXT 일반 가사 또는 LRC 시각 가사를 선택해 주세요.");
  if (typeof item.content !== "string") throw new LyricsError("가사 내용을 입력해 주세요.");
  const content = item.content.replace(/^\uFEFF/, "").replace(/\r\n|[\r\u0085\u2028\u2029]/g, "\n");
  lyricsLines(content, item.format);
  return { title, artist, album, duration: item.duration as number | null, format: item.format, content };
}

export function parseLyricsRecord(value: unknown): LyricsRecord {
  const item = object(value), input = parseLyricsInput(item);
  if (typeof item.id !== "string" || !UUID.test(item.id) || typeof item.version !== "number" || !Number.isSafeInteger(item.version) || item.version < 1) throw new LyricsError("가사 식별자와 버전을 확인해 주세요.");
  for (const key of ["createdAt", "updatedAt"] as const) {
    if (typeof item[key] !== "string" || !Number.isFinite(Date.parse(item[key])) || new Date(item[key]).toISOString() !== item[key]) throw new LyricsError("가사의 저장 시각을 확인해 주세요.");
  }
  return { ...input, id: item.id.toLowerCase(), version: item.version, createdAt: item.createdAt as string, updatedAt: item.updatedAt as string };
}

export function plainLyrics(record: LyricsInput): string { return lyricsLines(record.content, record.format).filter((line) => line.text.trim()).map((line) => line.text).join("\n"); }
export function exportLyrics(record: LyricsInput, format: LyricsFormat): string {
  if (format === "lrc" && record.format !== "lrc") throw new LyricsError("일반 가사에는 시각이 없어요. TXT로 내보낸 뒤 Mac 앱에서 시각을 맞출 수 있어요.");
  if (format === "plain" && record.format === "plain") { lyricsLines(record.content, "plain"); return record.content; }
  return format === "plain" ? plainLyrics(record) + "\n" : record.content;
}
export function decodeLyricsFile(bytes: ArrayBuffer, fileName: string): { content: string; format: LyricsFormat } {
  if (bytes.byteLength > MAX_LYRICS_BYTES) throw new LyricsError("파일은 1 MB까지 가져올 수 있어요.");
  const extension = fileName.split(".").at(-1)?.toLowerCase();
  if (extension !== "txt" && extension !== "lrc") throw new LyricsError("TXT 또는 LRC 파일 하나를 선택해 주세요.");
  const raw = new Uint8Array(bytes);
  const encoding = raw[0] === 255 && raw[1] === 254 ? "utf-16le" : raw[0] === 254 && raw[1] === 255 ? "utf-16be" : "utf-8";
  let content: string;
  try { content = new TextDecoder(encoding, { fatal: true }).decode(raw); }
  catch { throw new LyricsError("파일을 읽지 못했어요. UTF-8 또는 UTF-16으로 저장해 주세요."); }
  const format = extension === "lrc" ? "lrc" : "plain";
  lyricsLines(content, format);
  return { content, format };
}
