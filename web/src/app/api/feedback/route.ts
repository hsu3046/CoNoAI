// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 의견 저장: POST { mood?, message?, email?, website(봇 함정), elapsedMs }
// - 봇: 숨은 칸이 채워졌거나 폼을 연 지 2.5초 안에 보내면 조용히 성공처럼 버린다
// - 속도 제한: 같은 IP(해시) 10분 5건, 하루 20건
// - IP 원문은 저장하지 않는다 (소금 친 SHA-256)

import { createHash } from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase-admin";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

type Payload = { mood?: unknown; message?: unknown; email?: unknown; website?: unknown; elapsedMs?: unknown };

export async function POST(request: Request) {
  let payload: Payload;
  try {
    payload = (await request.json()) as Payload;
  } catch {
    return Response.json({ error: "잘못된 요청이에요." }, { status: 400 });
  }

  // 봇이면 성공처럼 답하고 버린다 (다시 시도하지 않게)
  if ((typeof payload.website === "string" && payload.website.length > 0) || (typeof payload.elapsedMs === "number" && payload.elapsedMs < 2500)) {
    return Response.json({ ok: true });
  }

  const mood = typeof payload.mood === "number" && Number.isInteger(payload.mood) && payload.mood >= 1 && payload.mood <= 5 ? payload.mood : null;
  const message = typeof payload.message === "string" ? payload.message.trim().slice(0, 2000) : "";
  const email = typeof payload.email === "string" ? payload.email.trim().slice(0, 200) : "";
  if (!mood && !message) {
    return Response.json({ error: "기분을 고르거나 한 줄이라도 남겨 주세요." }, { status: 400 });
  }
  if (email && !EMAIL.test(email)) {
    return Response.json({ error: "이메일 주소를 다시 확인해 주세요." }, { status: 400 });
  }

  const supabase = supabaseAdmin();
  const salt = process.env.FEEDBACK_IP_SALT;
  if (!supabase || !salt) {
    return Response.json({ error: "의견 받기를 준비하고 있어요." }, { status: 503 });
  }

  const ip = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || request.headers.get("x-real-ip") || "unknown";
  const ipHash = createHash("sha256").update(`${salt}:${ip}`).digest("hex");

  try {
    const now = Date.now();
    const [recent, daily] = await Promise.all([
      supabase.from("site_feedback").select("id", { count: "exact", head: true }).eq("ip_hash", ipHash).gte("created_at", new Date(now - 10 * 60_000).toISOString()),
      supabase.from("site_feedback").select("id", { count: "exact", head: true }).eq("ip_hash", ipHash).gte("created_at", new Date(now - 24 * 3_600_000).toISOString()),
    ]);
    if (recent.error || daily.error) throw recent.error ?? daily.error;
    if ((recent.count ?? 0) >= 5 || (daily.count ?? 0) >= 20) {
      return Response.json({ error: "조금 뒤에 다시 보내 주세요." }, { status: 429 });
    }

    const { error } = await supabase.from("site_feedback").insert({
      mood,
      message: message || null,
      email: email || null,
      ip_hash: ipHash,
      user_agent: request.headers.get("user-agent")?.slice(0, 300) ?? null,
    });
    if (error) throw error;
    return Response.json({ ok: true });
  } catch (error) {
    console.error("feedback insert failed", error);
    return Response.json({ error: "저장하지 못했어요. 잠시 뒤 다시 시도해 주세요." }, { status: 500 });
  }
}
