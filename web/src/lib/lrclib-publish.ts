// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { byteLength, LyricsError, lyricsLines, MAX_LYRICS_BYTES, type LyricsInput } from "./lyrics-record.ts";
export type PublishPayload = { trackName: string; artistName: string; albumName: string; duration: number; plainLyrics: string; syncedLyrics: string };
export type PublishChallenge = { prefix: string; target: string };
const BASE = "https://lrclib.net/api";
const CLIENT = "CoNo/0.2 (https://www.aib.vote)";
export const UNCERTAIN_PUBLICATION = "전송 후 응답을 확인하지 못했어요. 이미 공개되었을 수 있습니다. LRCLIB에서 곡을 확인한 뒤 다시 시도해 주세요. 자동 재전송은 하지 않습니다.";

type BackoffState = { until: number };
/** 같은 서버의 인증·게시 요청이 Retry-After 대기시간을 공유한다. 자동 재시도는 하지 않는다. */
export class LRCLIBPublishBackoff {
  private readonly now: () => number;
  private readonly state: BackoffState;
  constructor(now: () => number = Date.now, state: BackoffState = { until: 0 }) { this.now = now; this.state = state; }
  check(): void {
    const seconds = Math.max(0, Math.ceil((this.state.until - this.now()) / 1000));
    if (seconds > 0) throw this.error(seconds);
  }
  observe(response: Response): LyricsError | null {
    if (response.status !== 429) return null;
    const header = response.headers.get("retry-after")?.trim() ?? "";
    let seconds = /^\d+$/.test(header) ? Number(header) : (Date.parse(header) - this.now()) / 1000;
    if (!Number.isFinite(seconds) || seconds < 0 || seconds > Number.MAX_SAFE_INTEGER / 1000) seconds = 60;
    seconds = Math.ceil(seconds);
    this.state.until = Math.max(this.state.until, this.now() + seconds * 1000);
    return this.error(Math.max(0, Math.ceil((this.state.until - this.now()) / 1000)));
  }
  private error(seconds: number): LyricsError { return new LyricsError(`LRCLIB 요청 제한으로 ${seconds}초 뒤 다시 시도할 수 있어요. 개인 가사는 그대로입니다.`, 429, seconds); }
}
// 로컬 개발 서버의 모듈 재로드·라우트 분리에도 동일한 서비스 대기시간을 사용한다.
const shared = globalThis as typeof globalThis & { __conoLRCLIBPublishBackoff?: BackoffState };
const sharedBackoff = new LRCLIBPublishBackoff(Date.now, shared.__conoLRCLIBPublishBackoff ??= { until: 0 });

function stamp(time: number): string {
  const ms = Math.round(time * 1000);
  return `${String(Math.floor(ms / 60_000)).padStart(2, "0")}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}.${String(ms % 1000).padStart(3, "0")}`;
}
export function publishPayload(record: LyricsInput): PublishPayload {
  if (!record.title.trim() || !record.artist.trim() || record.duration === null || !Number.isFinite(record.duration) || record.duration <= 0 || record.duration > 86_400) throw new LyricsError("LRCLIB에 공개하려면 제목·가수와 실제 곡 길이(초)를 입력하고 저장해 주세요.");
  const lines = lyricsLines(record.content, record.format);
  if (lines.some((line) => line.time !== null && (line.text.trim() ? Math.round(line.time * 1000) / 1000 >= record.duration! : Math.round(line.time * 1000) / 1000 > record.duration!))) throw new LyricsError("가사 시작 시각은 실제 곡 길이보다 짧고, 빈 종료 시각은 곡 길이 이내여야 해요. 저장된 내용을 확인해 주세요.");
  const payload: PublishPayload = {
    trackName: record.title, artistName: record.artist, albumName: record.album, duration: record.duration,
    plainLyrics: lines.filter((line) => line.text.trim()).map((line) => line.text).join("\n"),
    // LRCLIB에는 검토한 줄 시각을 보낸다. 로컬 LRC의 메타데이터·단어 태그는 원본에 남긴다.
    syncedLyrics: record.format === "lrc" ? lines.map((line) => `[${stamp(line.time ?? 0)}] ${line.text}`).join("\n") : "",
  };
  if (byteLength(JSON.stringify(payload)) > MAX_LYRICS_BYTES) throw new LyricsError("공개할 가사와 곡 정보를 합친 크기는 1 MB 이하여야 해요. 개인 보관함의 원문은 유지됩니다.");
  return payload;
}
export function parseChallenge(value: unknown): PublishChallenge {
  if (!value || typeof value !== "object") throw new LyricsError("LRCLIB 인증 응답을 읽지 못했어요.", 502);
  const data = value as Record<string, unknown>;
  if (typeof data.prefix !== "string" || !/^[a-zA-Z0-9]{1,256}$/.test(data.prefix) || typeof data.target !== "string" || !/^[0-9a-fA-F]{64}$/.test(data.target) || /^0+$/.test(data.target)) throw new LyricsError("LRCLIB 인증 응답을 읽지 못했어요.", 502);
  return { prefix: data.prefix, target: data.target.toLowerCase() };
}
export async function requestPublishChallenge(signal: AbortSignal, transport: typeof fetch = fetch, backoff: LRCLIBPublishBackoff = sharedBackoff): Promise<PublishChallenge> {
  signal.throwIfAborted();
  backoff.check();
  let response: Response;
  try { response = await transport(`${BASE}/request-challenge`, { method: "POST", headers: { "Lrclib-Client": CLIENT, "User-Agent": CLIENT }, signal, redirect: "error" }); }
  catch {
    signal.throwIfAborted();
    throw new LyricsError("LRCLIB에 연결하지 못했어요. 개인 가사는 그대로입니다. 잠시 뒤 다시 시도해 주세요.", 502);
  }
  const restricted = backoff.observe(response);
  if (restricted) { await response.body?.cancel().catch(() => {}); throw restricted; }
  if (response.status !== 200) { await response.body?.cancel().catch(() => {}); throw new LyricsError(`LRCLIB 인증 요청이 거절됐어요 (HTTP ${response.status}).`, 502); }
  const reader = response.body?.getReader();
  if (!reader) throw new LyricsError("LRCLIB 인증 응답이 비어 있어요.", 502);
  const chunks: Uint8Array[] = []; let size = 0;
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    size += value.byteLength;
    if (size > 4096) { await reader.cancel(); throw new LyricsError("LRCLIB 인증 응답이 앱의 4 KB 한도를 넘었어요.", 502); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let value: unknown;
  try { value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new LyricsError("LRCLIB 인증 응답을 읽지 못했어요.", 502); }
  signal.throwIfAborted();
  return parseChallenge(value);
}
export async function sendPublication(payload: PublishPayload, token: string, signal: AbortSignal, transport: typeof fetch = fetch, backoff: LRCLIBPublishBackoff = sharedBackoff): Promise<void> {
  if (!/^[a-zA-Z0-9]{1,256}:\d{1,20}$/.test(token)) throw new LyricsError("게시 인증 토큰을 확인해 주세요.");
  signal.throwIfAborted();
  backoff.check();
  let response: Response;
  try {
    response = await transport(`${BASE}/publish`, { method: "POST", headers: { "Lrclib-Client": CLIENT, "User-Agent": CLIENT, "Content-Type": "application/json", "X-Publish-Token": token }, body: JSON.stringify(payload), signal, redirect: "error" });
  } catch { throw new LyricsError(UNCERTAIN_PUBLICATION, 502); }
  const restricted = backoff.observe(response);
  // 이미 받은 성공/거절 상태를 응답 스트림 정리 실패로 뒤집지 않는다.
  await response.body?.cancel().catch(() => {});
  if (restricted) throw restricted;
  if (response.status !== 201) throw new LyricsError(`LRCLIB 게시 요청이 거절됐어요 (HTTP ${response.status}). 개인 가사는 그대로입니다.`, 502);
}

/** Web Worker에서 실행. 공식 규약 SHA256(prefix + nonce) <= target이며 토큰에만 ':'를 쓴다. */
export async function solvePublishChallenge(value: PublishChallenge, options: { maximumAttempts?: number; timeoutMs?: number; now?: () => number; hash?: (text: string) => Promise<string>; checkCancelled?: () => void } = {}): Promise<string> {
  const challenge = parseChallenge(value);
  const now = options.now ?? (() => performance.now());
  const deadline = now() + Math.min(120_000, options.timeoutMs ?? 120_000);
  const limit = Math.min(100_000_000, options.maximumAttempts ?? 100_000_000);
  const encoder = new TextEncoder();
  const hash = options.hash ?? (async (text: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text))), (byte) => byte.toString(16).padStart(2, "0")).join(""));
  for (let nonce = 0; nonce < limit; nonce++) {
    options.checkCancelled?.();
    if (now() >= deadline) break;
    const digest = await hash(challenge.prefix + nonce);
    options.checkCancelled?.();
    if (now() >= deadline) break;
    if (digest <= challenge.target) return `${challenge.prefix}:${nonce}`;
  }
  throw new LyricsError("게시 인증 계산이 오래 걸려 멈췄어요. 나중에 다시 시도하거나 TXT/LRC로 내보내 주세요.");
}
