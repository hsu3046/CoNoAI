// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { failure, payload, RequestError, session } from "@/lib/local-http";
import { LyricsError } from "@/lib/lyrics-record";
import { lyricsRepository } from "@/lib/lyrics-repository";
import { ownedLyrics } from "@/lib/lyrics-service";
import { publishPayload, requestPublishChallenge, sendPublication } from "@/lib/lrclib-publish";
import { object } from "@/lib/score-record";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const user = session(request);
  try {
    let body: Record<string, unknown>;
    try { body = object(await payload(request, 4096)); }
    catch (error) { if (error instanceof RequestError) throw error; throw new RequestError("게시 요청 형식을 확인해 주세요."); }
    if (body.consent !== true || !Number.isSafeInteger(body.version) || (body.action !== "challenge" && body.action !== "publish")) throw new RequestError("공개 내용을 검토하고 동의한 뒤 다시 시도해 주세요.");
    const data = await lyricsRepository().read();
    const record = ownedLyrics(data, user.id, body.id, body.version);
    const publication = publishPayload(record);
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(20_000)]);
    if (body.action === "challenge") return Response.json({ challenge: await requestPublishChallenge(signal) }, { headers: user.headers });
    if (typeof body.token !== "string") throw new RequestError("게시 인증 토큰을 확인해 주세요.");
    await sendPublication(publication, body.token, signal);
    return Response.json({ ok: true }, { headers: user.headers });
  } catch (error) {
    if (error instanceof LyricsError && error.status === 429) return Response.json({ error: error.message, retryAfterSeconds: error.retryAfterSeconds ?? 60 }, { status: 429, headers: { ...user.headers, "Retry-After": String(error.retryAfterSeconds ?? 60) } });
    return failure(error instanceof LyricsError ? new RequestError(error.message, error.status) : error instanceof DOMException ? new RequestError("LRCLIB 연결이 취소되었거나 응답 시간이 초과됐어요. 개인 가사는 그대로입니다.", 502) : error);
  }
}
