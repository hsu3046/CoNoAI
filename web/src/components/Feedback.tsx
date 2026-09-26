// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 의견 받기: 기분 이모지 + 한 줄 의견 + (선택) 이메일 → /api/feedback

"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { release } from "@/lib/release";
import { SectionTitle } from "./TryItLive";

const MOODS = [
  { value: 1, emoji: "😴", label: "글쎄요" },
  { value: 2, emoji: "🙂", label: "괜찮아요" },
  { value: 3, emoji: "😄", label: "재밌어요" },
  { value: 4, emoji: "🤩", label: "최고예요" },
  { value: 5, emoji: "🔥", label: "매일 쓸래요" },
] as const;

type Status = { kind: "idle" } | { kind: "sending" } | { kind: "sent" } | { kind: "error"; message: string };

export function Feedback() {
  const [mood, setMood] = useState<number | null>(null);
  const [message, setMessage] = useState("");
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  // 봇 걸러내기: 사람은 이 칸을 보지 못하고, 폼을 연 뒤 몇 초는 지나야 보낸다
  const [trap, setTrap] = useState("");
  const openedAt = useRef(0);
  useEffect(() => {
    openedAt.current = Date.now();
  }, []);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!mood && !message.trim()) {
      setStatus({ kind: "error", message: "기분을 고르거나 한 줄이라도 남겨 주세요." });
      return;
    }
    setStatus({ kind: "sending" });
    try {
      const response = await fetch("/api/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mood, message: message.trim(), email: email.trim(), website: trap, elapsedMs: Date.now() - openedAt.current }),
      });
      const body = (await response.json().catch(() => ({}))) as { error?: string };
      if (!response.ok) throw new Error(body.error ?? "잠시 뒤 다시 시도해 주세요.");
      setStatus({ kind: "sent" });
    } catch (caught) {
      setStatus({ kind: "error", message: caught instanceof Error ? caught.message : "보내지 못했어요." });
    }
  };

  return (
    <section id="feedback" className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="FEEDBACK" title="써 보니 어떠세요?" />
      <p className="mx-auto mt-4 max-w-xl text-center text-ink2">
        불편한 점, 바라는 기능, 칭찬 한 스푼 — 무엇이든 좋아요. 이메일을 남기면 챌린지·새 버전 소식을 먼저 보내 드려요.
      </p>

      <div className="mx-auto mt-12 max-w-2xl">
        {status.kind === "sent" ? (
          <div className="rounded-3xl border border-mint/40 bg-mint/10 p-10 text-center">
            <p className="text-6xl" style={{ animation: "floaty 3s ease-in-out infinite" }}>
              💌
            </p>
            <p className="mt-4 font-cute text-3xl">고마워요!</p>
            <p className="mt-2 text-ink2">하나하나 다 읽고 있어요.</p>
          </div>
        ) : (
          <form onSubmit={submit} className="space-y-6 rounded-3xl border border-white/10 bg-white/[0.03] p-6 sm:p-8" noValidate>
            <fieldset>
              <legend className="font-cute text-lg">지금 기분은?</legend>
              <div className="mt-3 grid grid-cols-5 gap-2">
                {MOODS.map((item) => {
                  const selected = mood === item.value;
                  return (
                    <button
                      key={item.value}
                      type="button"
                      onClick={() => setMood(selected ? null : item.value)}
                      aria-pressed={selected}
                      aria-label={item.label}
                      title={item.label}
                      className={`flex flex-col items-center gap-1 rounded-2xl border px-1 py-3 transition ${
                        selected ? "scale-105 border-pink bg-pink/15" : "border-white/10 bg-black/20 hover:border-white/30"
                      }`}
                    >
                      <span className={`text-3xl transition-transform ${selected ? "scale-125" : ""}`}>{item.emoji}</span>
                      <span className="hidden text-xs text-ink2 sm:block">{item.label}</span>
                    </button>
                  );
                })}
              </div>
              <p className="mt-2 h-4 text-center text-xs text-pink sm:hidden">{MOODS.find((item) => item.value === mood)?.label ?? ""}</p>
            </fieldset>

            <label className="block">
              <span className="font-cute text-lg">한마디</span>
              <textarea
                value={message}
                onChange={(event) => setMessage(event.target.value)}
                maxLength={2000}
                rows={4}
                placeholder="예: 가사 싱크가 딱 맞아서 놀랐어요 / 멜론에서도 가사가 나오면 좋겠어요"
                className="mt-2 w-full resize-y rounded-2xl border border-white/10 bg-black/30 px-4 py-3 text-base text-ink placeholder:text-faint focus:border-pink focus:outline-none"
              />
              <span className="mt-1 block text-right text-xs text-faint">{message.length} / 2000</span>
            </label>

            <label className="block">
              <span className="font-cute text-lg">
                이메일 <span className="text-sm text-faint">(선택 · 소식 받기용)</span>
              </span>
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                maxLength={200}
                placeholder="you@example.com"
                autoComplete="email"
                className="mt-2 w-full rounded-2xl border border-white/10 bg-black/30 px-4 py-3 text-base text-ink placeholder:text-faint focus:border-pink focus:outline-none"
              />
            </label>

            {/* 사람에겐 보이지 않는 칸 (봇이 채우면 거른다) */}
            <input
              type="text"
              name="website"
              tabIndex={-1}
              autoComplete="off"
              value={trap}
              onChange={(event) => setTrap(event.target.value)}
              className="absolute -left-[9999px] size-px opacity-0"
              aria-hidden
            />

            {status.kind === "error" && (
              <p className="rounded-xl bg-stop/15 px-4 py-2 text-sm text-stop">
                {status.message}{" "}
                <a href={`${release.repositoryUrl}/issues/new`} className="underline underline-offset-2">
                  GitHub 로 남기기
                </a>
              </p>
            )}

            <button
              type="submit"
              disabled={status.kind === "sending"}
              className="w-full rounded-full bg-pink py-4 font-cute text-xl text-night shadow-[0_0_30px_rgba(255,143,176,0.5)] transition hover:scale-[1.02] disabled:opacity-60"
            >
              {status.kind === "sending" ? "보내는 중…" : "보내기 💌"}
            </button>
            <p className="text-center text-xs text-faint">이메일은 소식 전달에만 쓰고, 언제든 지워 달라고 하실 수 있어요.</p>
          </form>
        )}
      </div>
    </section>
  );
}
