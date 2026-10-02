// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useState } from "react";
import { requestJSON } from "@/lib/score-client";
import { Screen, SectionTitle } from "./Screen";
export const SUPPORT_EMAIL = "support@aib.vote";
export function Feedback() {
  const [mood, setMood] = useState<number | null>(null);
  const [message, setMessage] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  return <Screen id="feedback" glow={{ color: "rgba(255,143,176,0.09)", x: "50%", y: "50%" }}>
    <SectionTitle kicker="FEEDBACK" title="써 보니 어떠세요?">불편한 점, 바라는 기능, 칭찬 한 스푼 — 무엇이든 남겨 주세요.</SectionTitle>
    <form className="mx-auto mt-8 max-w-xl space-y-5" onSubmit={async (event) => {
      event.preventDefault(); if (busy) return; setBusy(true); setNotice("");
      try { await requestJSON("/api/feedback", { mood, message, email, website: "" }); setNotice("로컬에 의견을 저장했어요. 고맙습니다!"); setMessage(""); setEmail(""); setMood(null); }
      catch (error) { setNotice(error instanceof Error ? error.message : "저장하지 못했어요. 다시 시도해 주세요."); }
      finally { setBusy(false); }
    }}>
      <fieldset disabled={busy} className="space-y-4">
        <legend className="sr-only">의견 작성</legend>
        <div className="flex justify-center gap-3" aria-label="만족도">{["😕", "🙂", "😊", "🥰", "🤩"].map((face, index) => <button type="button" key={face} aria-label={`${index + 1}점`} aria-pressed={mood === index + 1} className={`rounded-xl border p-3 text-3xl ${mood === index + 1 ? "border-pink bg-pink/15" : "border-white/15"}`} onClick={() => setMood(index + 1)}>{face}</button>)}</div>
        <label className="block">의견<textarea className="mt-2 min-h-32 w-full rounded-2xl border border-white/20 bg-black/30 p-4 text-base" maxLength={2000} value={message} onChange={(e) => setMessage(e.target.value)} /></label>
        <label className="block">이메일 <span className="text-sm text-faint">(선택)</span><input type="email" className="mt-2 w-full rounded-xl border border-white/20 bg-black/30 p-3 text-base" maxLength={200} value={email} onChange={(e) => setEmail(e.target.value)} /></label>
        <p className="text-sm text-ink2">지금은 로컬 테스트입니다. 의견과 이메일은 이 서버에만 저장되며 메일이 발송되지 않아요.</p>
        <button disabled={!mood && !message.trim()} className="w-full rounded-full bg-pink py-3 font-cute text-xl text-night disabled:opacity-50">{busy ? "저장 중…" : "의견 남기기"}</button>
      </fieldset>
      <p role="status" className="text-center text-mint">{notice}</p>
      <p className="text-center text-sm text-ink2">메일로 보내려면 <a href={`mailto:${SUPPORT_EMAIL}`} className="underline">{SUPPORT_EMAIL}</a></p>
    </form>
  </Screen>;
}
