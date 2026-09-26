// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 서버 전용 Supabase 클라이언트 (service role). API route 에서만 import 한다 — 브라우저 번들에 넣지 말 것.
// 쿠키 없는 supabase-js 클라이언트여야 한다: @supabase/ssr 에 service 키를 주면 사용자 JWT 가 붙어 RLS 를 탄다.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let client: SupabaseClient | null = null;

/** 환경 변수가 없으면 null (의견 받기를 끈 상태로 동작) */
export function supabaseAdmin(): SupabaseClient | null {
  if (client) return client;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  return client;
}
