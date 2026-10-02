// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { downloadBlob } from "./score-client";
import { exportLyrics, type LyricsFormat, type LyricsInput } from "./lyrics-record";
export class LyricsRequestError extends Error {
  readonly status: number;
  readonly retryAfterSeconds?: number;
  constructor(message: string, status: number, retryAfterSeconds?: number) { super(message); this.status = status; this.retryAfterSeconds = retryAfterSeconds; }
}
export async function lyricsRequest<T>(url: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(url, { method: body === undefined ? "GET" : "POST", cache: "no-store", headers: body === undefined ? undefined : { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(25_000)]) : AbortSignal.timeout(15_000) });
  let data: unknown;
  try { data = await response.json(); } catch { throw new Error("서버 응답을 읽지 못했어요. 입력 내용은 그대로입니다."); }
  if (!response.ok) {
    const retry = data && typeof data === "object" && "retryAfterSeconds" in data && typeof data.retryAfterSeconds === "number" && Number.isFinite(data.retryAfterSeconds) ? Math.max(0, data.retryAfterSeconds) : undefined;
    throw new LyricsRequestError(data && typeof data === "object" && "error" in data && typeof data.error === "string" ? data.error : "요청을 처리하지 못했어요.", response.status, retry);
  }
  return data as T;
}
export function downloadLyrics(input: LyricsInput, format: LyricsFormat): void {
  const name = (input.title || "CoNo-lyrics").replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").slice(0, 100);
  downloadBlob(new Blob([exportLyrics(input, format)], { type: "text/plain;charset=utf-8" }), `${name}.${format === "plain" ? "txt" : "lrc"}`);
}
