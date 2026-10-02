// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { failure, payload, RequestError, session } from "@/lib/local-http";
import { lyricsRepository } from "@/lib/lyrics-repository";
import { changeLyrics } from "@/lib/lyrics-service";
import { LyricsError, MAX_LYRICS_BYTES } from "@/lib/lyrics-record";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const user = session(request);
  try {
    const data = await lyricsRepository().read();
    const records = data.lyrics.filter((entry) => entry.ownerId === user.id).map((entry) => entry.record).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    return Response.json({ records }, { headers: user.headers });
  } catch (error) { return failure(error); }
}
export async function POST(request: Request) {
  const user = session(request);
  try {
    // JSON 문자열 이스케이프와 메타데이터는 가사 본문의 1 MB 한도와 별도다.
    const body = await payload(request, MAX_LYRICS_BYTES * 2 + 65_536);
    const record = await lyricsRepository().update((data) => changeLyrics(data, user.id, body));
    return Response.json({ record }, { headers: user.headers });
  } catch (error) {
    return failure(error instanceof LyricsError ? new RequestError(error.message, error.status) : error instanceof TypeError ? new RequestError("요청 형식을 확인해 주세요.") : error);
  }
}
