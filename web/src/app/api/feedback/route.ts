// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { randomUUID } from "node:crypto";
import { repository } from "@/lib/local-repository";
import { failure, payload, RequestError, session } from "@/lib/local-http";
import { object } from "@/lib/score-record";

export async function POST(request: Request) {
  const user = session(request);
  try {
    let v: Record<string, unknown>;
    try { v = object(await payload(request)); } catch (error) { if (error instanceof RequestError) throw error; throw new RequestError("요청을 확인해 주세요."); }
    if (typeof v.website === "string" && v.website) return Response.json({ ok: true }, { headers: user.headers });
    const mood = typeof v.mood === "number" && Number.isInteger(v.mood) && v.mood >= 1 && v.mood <= 5 ? v.mood : null;
    const message = typeof v.message === "string" ? v.message.trim() : "";
    const email = typeof v.email === "string" ? v.email.trim() : "";
    if ((!mood && !message) || message.length > 2000 || email.length > 200 || (email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email))) throw new RequestError("의견(최대 2,000자)과 이메일 주소를 확인해 주세요.");
    await repository().update((data) => {
      if (data.feedback.filter((v) => v.ownerId === user.id && Date.parse(v.createdAt) > Date.now() - 600_000).length >= 5) throw new RequestError("조금 뒤에 다시 보내 주세요.", 429);
      data.feedback.push({ id: randomUUID(), ownerId: user.id, createdAt: new Date().toISOString(), mood, message, email });
    });
    return Response.json({ ok: true }, { headers: user.headers });
  } catch (error) { return failure(error); }
}
