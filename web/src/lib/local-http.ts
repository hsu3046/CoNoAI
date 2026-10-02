// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { randomUUID } from "node:crypto";
import { LocalStoreError } from "./local-repository";
import { UUID } from "./score-record";
export class RequestError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) { super(message); this.status = status; }
}
export function session(request: Request) {
  const cookie = request.headers.get("cookie")?.split(";").map((v) => v.trim()).find((v) => v.startsWith("cono-session="))?.slice(13);
  const id = cookie && UUID.test(cookie) ? cookie.toLowerCase() : randomUUID();
  return { id, headers: { "Set-Cookie": `cono-session=${id}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`, "Cache-Control": "no-store" } };
}
export async function payload(request: Request): Promise<unknown> {
  const origin = request.headers.get("origin");
  // Next 개발 서버는 내부 URL의 호스트를 정규화할 수 있으므로 실제 Host와 비교한다.
  if (origin) {
    let parsed: URL;
    try { parsed = new URL(origin); } catch { throw new RequestError("요청 출처를 확인해 주세요.", 403); }
    if (!["http:", "https:"].includes(parsed.protocol) || parsed.host !== (request.headers.get("host") ?? new URL(request.url).host)) throw new RequestError("같은 사이트에서 다시 시도해 주세요.", 403);
  }
  if (!request.headers.get("content-type")?.includes("application/json")) throw new RequestError("JSON 요청이 필요해요.", 415);
  const reader = request.body?.getReader();
  if (!reader) throw new RequestError("요청 내용이 없어요.");
  let length = 0;
  const chunks: Uint8Array[] = [];
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > 1024 * 1024) { await reader.cancel(); throw new RequestError("파일은 1 MB까지 가져올 수 있어요.", 413); }
    chunks.push(value);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new RequestError("JSON을 읽지 못했어요."); }
}
export function failure(error: unknown): Response {
  const status = error instanceof RequestError ? error.status : error instanceof LocalStoreError ? 503 : 500;
  const message = error instanceof RequestError || error instanceof LocalStoreError ? error.message : "저장하지 못했어요. 잠시 뒤 다시 시도해 주세요.";
  return Response.json({ error: message }, { status, headers: { "Cache-Control": "no-store" } });
}
