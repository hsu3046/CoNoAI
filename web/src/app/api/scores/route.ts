// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { repository } from "@/lib/local-repository";
import { createHash } from "node:crypto";
import { failure, payload, RequestError, session } from "@/lib/local-http";
import { MAX_ARCHIVE_BYTES, object, parseDocument, parseRecord } from "@/lib/score-record";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const user = session(request);
  try {
    const data = await repository().read();
    return Response.json({ nickname: data.profiles[user.id]?.nickname ?? "나의 무대", records: data.scores.filter((v) => v.ownerId === user.id).sort((a, b) => b.record.createdAt.localeCompare(a.record.createdAt)).map(({ record, published }) => ({ ...record, published })) }, { headers: user.headers });
  } catch (error) { return failure(error); }
}
export async function POST(request: Request) {
  const user = session(request);
  try {
    let body: Record<string, unknown>;
    // 전송용 action/document 래퍼는 백업 파일의 1 MB 제한과 별도로 계산한다.
    try { body = object(await payload(request, MAX_ARCHIVE_BYTES + 65_536)); }
    catch (error) { if (error instanceof RequestError) throw error; throw new RequestError("요청 형식을 확인해 주세요."); }
    let records;
    try { records = body.action === "import" ? parseDocument(body.document).records : body.action === "save" ? [parseRecord(body.record)] : []; }
    catch (error) { throw new RequestError(error instanceof Error ? error.message : "기록을 확인해 주세요."); }
    await repository().update((data) => {
      if (body.action === "save" || body.action === "import") {
        for (const incoming of records) {
          let record = incoming;
          let existing = data.scores.find((v) => v.record.id === record.id);
          if (existing && JSON.stringify(parseRecord(existing.record)) !== JSON.stringify(record)) throw new RequestError("같은 ID의 다른 기록이 있어요. 원본을 확인해 주세요.", 409);
          if (body.action === "import") {
            // 새 브라우저/쿠키에서도 백업을 복원한다. 기존 소유권은 보존하고, 반복 가져오기는 같은 사본 ID로 합친다.
            const hash = createHash("sha256").update(`${user.id}:${record.id}`).digest("hex");
            const id = `${hash.slice(0, 8)}-${hash.slice(8, 12)}-4${hash.slice(13, 16)}-8${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
            const copy = data.scores.find((v) => v.record.id === id);
            // 원 소유자가 기록을 지운 뒤에도 이미 만든 사본을 다시 사용한다.
            if (copy || (existing && existing.ownerId !== user.id)) {
              record = { ...record, id };
              existing = copy;
              if (existing && (existing.ownerId !== user.id || JSON.stringify(parseRecord(existing.record)) !== JSON.stringify(record))) throw new RequestError("백업 사본과 충돌하는 기록이 있어요.", 409);
            }
          } else if (existing && existing.ownerId !== user.id) {
            throw new RequestError("다른 사용자의 기록 ID예요. JSON 가져오기를 이용해 주세요.", 409);
          }
          if (!existing) data.scores.push({ ownerId: user.id, record, published: false });
        }
        const mine = data.scores.filter((v) => v.ownerId === user.id).map((v) => v.record);
        try { parseDocument({ schemaVersion: 1, records: mine }); }
        catch { throw new RequestError("기록은 최대 1,000곡·1 MB까지 저장할 수 있어요. JSON으로 내보낸 뒤 정리해 주세요."); }
      } else if (body.action === "profile") {
        if (typeof body.nickname !== "string" || !body.nickname.trim() || body.nickname.trim().length > 24) throw new RequestError("닉네임은 1~24자로 적어 주세요.");
        data.profiles[user.id] = { nickname: body.nickname.trim() };
      } else if (body.action === "publish" || body.action === "delete") {
        const index = data.scores.findIndex((v) => v.ownerId === user.id && v.record.id === body.id);
        if (index < 0) throw new RequestError("기록을 찾지 못했어요.", 404);
        if (body.action === "delete") data.scores.splice(index, 1);
        else {
          if (typeof body.published !== "boolean") throw new RequestError("공개 여부를 확인해 주세요.");
          if (data.scores[index].record.source === "demo") throw new RequestError("데모 점수는 챌린지에 올릴 수 없어요.");
          data.scores[index].published = body.published;
        }
      } else throw new RequestError("지원하지 않는 요청이에요.");
    });
    return Response.json({ ok: true }, { headers: user.headers });
  } catch (error) { return failure(error); }
}
