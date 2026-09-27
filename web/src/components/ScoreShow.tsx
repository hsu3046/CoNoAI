// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 체험이 끝나면 뜨는 점수 연출 (앱의 CelebrationView 와 같은 순서):
// 드럼롤 동안 점수가 게이지와 함께 올라가고, 2.8초 심벌에 쾅 — 번쩍 · 흔들림 · 불꽃 · 폭죽 · 별.

"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { drawConfetti, drawFireworks, flashAmount, makeShow, shake } from "@/fx/fireworks";
import { fitCanvas } from "@/fx/hooks";
import { playCelebration } from "@/fx/sfx";
import { scoreComment, type SongScore } from "@/lib/pitch";

const CRASH = 2.8;

export function ScoreShow({
  result,
  audio,
  onClose,
  onRetry,
}: {
  result: SongScore;
  audio: AudioContext | null;
  onClose: () => void;
  onRetry: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const cardRef = useRef<HTMLDivElement>(null);
  const [elapsed, setElapsed] = useState(0);
  const [shared, setShared] = useState<string | null>(null);
  // 같은 결과면 같은 불꽃 (렌더 중 난수 금지)
  const show = useMemo(() => makeShow(result.score, result.score * 7919 + result.notesHit * 31 + result.bestStreak, CRASH), [result]);

  useEffect(() => {
    let stopSound: (() => void) | undefined;
    let cancelled = false;
    const startWall = performance.now() / 1000 + 0.1;
    const startAudio = audio ? audio.currentTime + 0.1 : 0;
    if (audio) {
      void playCelebration(audio, show, startAudio).then((stop) => {
        if (cancelled) stop();
        else stopSound = stop;
      });
    }
    let frame = 0;
    const draw = () => {
      frame = requestAnimationFrame(draw);
      // 소리와 같은 시계로 (소리가 없으면 벽시계)
      const t = audio ? audio.currentTime - startAudio : performance.now() / 1000 - startWall;
      setElapsed(t);
      const canvas = canvasRef.current;
      if (!canvas) return;
      const { width, height, ctx } = fitCanvas(canvas);
      if (!ctx) return;
      ctx.clearRect(0, 0, width, height);
      drawFireworks(ctx, show, t, width, height);
      drawConfetti(ctx, t - CRASH, width, height, 11);
      const offset = shake(show, t);
      if (cardRef.current) cardRef.current.style.transform = `translate(${offset.x}px, ${offset.y}px)`;
    };
    frame = requestAnimationFrame(draw);
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
      stopSound?.();
      window.removeEventListener("keydown", onKey);
    };
  }, [audio, show, onClose]);

  const landed = elapsed >= CRASH;
  const since = elapsed - CRASH;
  const progress = Math.min(1, Math.max(0, elapsed / CRASH));
  const eased = 1 - Math.pow(1 - progress, 3);
  const shown = landed ? result.score : Math.floor(result.score * eased);
  const slam = landed ? 0.5 * Math.exp(-since * 7) * Math.cos(since * 20) : 0.04 * progress * Math.sin(elapsed * Math.PI * 14);
  const reveal = (delay: number) => Math.min(1, Math.max(0, (since - delay) / 0.35));
  const stars = Math.round(result.score / 10) / 2;
  const fill = (result.score / 100) * eased;
  const flash = flashAmount(show, elapsed);

  const share = async () => {
    const text = `🎤 CoNo 브라우저 노래방에서 ${result.score}점! (${scoreComment(result.score)}) 너도 불러 봐 →`;
    const url = `${window.location.origin}/#try`;
    try {
      if (navigator.share) {
        await navigator.share({ title: "CoNo 점수 자랑", text, url });
        return;
      }
      await navigator.clipboard.writeText(`${text} ${url}`);
      setShared("복사했어요! 붙여넣어 자랑하세요");
    } catch {
      // 공유 창을 닫은 경우 — 조용히
    }
  };

  // body 로 띄운다: 섹션이 쌓임 맥락(isolate)을 만들면 고정 헤더가 연출 위로 올라온다
  return createPortal(
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center overflow-hidden px-4"
      role="dialog"
      aria-modal="true"
      aria-label={`채점 결과 ${result.score}점`}
    >
      <div
        className="absolute inset-0 backdrop-blur-md"
        style={{ background: "radial-gradient(ellipse at center, rgba(5,6,14,0.86), rgba(5,6,14,0.97))", opacity: Math.min(1, elapsed / 0.35) }}
        onClick={onClose}
      />
      <canvas ref={canvasRef} className="pointer-events-none absolute inset-0 size-full" />
      <div ref={cardRef} className="relative flex flex-col items-center text-center" style={{ opacity: Math.min(1, elapsed / 0.4) }}>
        {/* 빛줄기 */}
        <div
          className="pointer-events-none absolute left-1/2 top-[150px] size-[620px] -translate-x-1/2 -translate-y-1/2 rounded-full"
          style={{
            background: "repeating-conic-gradient(from 0deg, rgba(255,204,92,0.22) 0deg 7deg, transparent 7deg 20deg)",
            maskImage: "radial-gradient(circle, black 20%, transparent 68%)",
            WebkitMaskImage: "radial-gradient(circle, black 20%, transparent 68%)",
            opacity: landed ? Math.min(1, since / 0.3) : 0,
            transform: `translate(-50%, -50%) rotate(${elapsed * 20}deg) scale(${landed ? 0.8 + 0.2 * Math.min(1, since / 0.5) : 0.8})`,
          }}
        />
        <div className="relative grid size-[min(300px,72vw)] place-items-center">
          <svg viewBox="0 0 300 300" className="absolute inset-0 -rotate-90" aria-hidden>
            <defs>
              <linearGradient id="gauge" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stopColor="#ffcc5c" />
                <stop offset="55%" stopColor="#ff9a4d" />
                <stop offset="100%" stopColor="#ff8fb0" />
              </linearGradient>
            </defs>
            <circle cx="150" cy="150" r="136" fill="none" stroke="rgba(255,255,255,0.09)" strokeWidth="18" />
            {/* 빛 번짐: drop-shadow 필터는 자기 영역을 따로 합성해 뒤의 불꽃을 네모로 가린다 → 옅은 굵은 고리 */}
            <circle
              cx="150"
              cy="150"
              r="136"
              fill="none"
              stroke="url(#gauge)"
              strokeOpacity={landed ? 0.28 : 0.12}
              strokeWidth="40"
              strokeLinecap="round"
              strokeDasharray={2 * Math.PI * 136}
              strokeDashoffset={2 * Math.PI * 136 * (1 - fill)}
            />
            <circle
              cx="150"
              cy="150"
              r="136"
              fill="none"
              stroke="url(#gauge)"
              strokeWidth="18"
              strokeLinecap="round"
              strokeDasharray={2 * Math.PI * 136}
              strokeDashoffset={2 * Math.PI * 136 * (1 - fill)}
            />
          </svg>
          <div style={{ transform: `scale(${1 + slam})` }}>
            <p
              className="font-display text-[clamp(96px,26vw,150px)] leading-none tabular-nums"
              style={{
                background: "linear-gradient(180deg,#fff8c7,#ffcc5c 55%,#ff8a38)",
                WebkitBackgroundClip: "text",
                backgroundClip: "text",
                color: "transparent",
                textShadow: `0 0 ${landed ? 30 : 12}px rgba(255,150,50,${landed ? 0.85 : 0.4})`,
              }}
            >
              {shown}
            </p>
            <p className="-mt-2 font-cute text-xl text-ink2">점</p>
          </div>
        </div>

        <div className="mt-4 flex gap-2.5" aria-hidden>
          {[0, 1, 2, 3, 4].map((index) => {
            const t = since - 0.12 - index * 0.11;
            const pop = t <= 0 ? 0 : 1 + 0.55 * Math.exp(-t * 8) * Math.sin(t * 18);
            const full = stars >= index + 1;
            const half = !full && stars >= index + 0.5;
            return (
              <span
                key={index}
                className="inline-block"
                style={{ transform: `scale(${Math.max(0, pop)}) rotate(${t <= 0 ? -60 : -60 * Math.exp(-t * 7)}deg)` }}
              >
                <Star fill={full ? 1 : half ? 0.5 : 0} id={`star-${index}`} />
              </span>
            );
          })}
        </div>

        <p
          className="mt-3 font-display text-[clamp(34px,8vw,48px)]"
          style={{
            background: "linear-gradient(90deg,#ffcc5c,#ff9e66,#ff8fb0)",
            WebkitBackgroundClip: "text",
            backgroundClip: "text",
            color: "transparent",
            opacity: reveal(0.55),
            transform: `scale(${reveal(0.55) > 0 ? 1 + 0.25 * Math.exp(-(since - 0.55) * 8) : 1})`,
          }}
        >
          {scoreComment(result.score)}
        </p>

        <div className="mt-4 flex flex-wrap justify-center gap-2.5" style={{ opacity: reveal(0.85), transform: `translateY(${14 * (1 - reveal(0.85))}px)` }}>
          <Chip label="맞춘 음표" value={`${result.notesHit} / ${result.notesTotal}`} />
          <Chip label="최고 연속" value={`${result.bestStreak}`} />
        </div>

        <div className="mt-6 flex flex-wrap justify-center gap-3" style={{ opacity: reveal(1.2), pointerEvents: reveal(1.2) > 0.5 ? "auto" : "none" }}>
          <button type="button" onClick={onRetry} className="rounded-full border border-white/20 bg-white/5 px-5 py-3 font-cute text-lg transition hover:border-pink hover:text-pink">
            ↺ 다시 부르기
          </button>
          <button type="button" onClick={share} className="rounded-full bg-pink px-5 py-3 font-cute text-lg text-night shadow-[0_0_24px_rgba(255,143,176,0.6)] transition hover:scale-105">
            📣 점수 자랑하기
          </button>
          <a href="#download" onClick={onClose} className="rounded-full bg-gold px-5 py-3 font-cute text-lg text-night shadow-[0_0_24px_rgba(255,204,92,0.6)] transition hover:scale-105">
            진짜 노래로 하기 →
          </a>
        </div>
        {shared && <p className="mt-3 text-sm text-mint">{shared}</p>}
        <p className="mt-4 text-xs text-faint" style={{ opacity: reveal(1.8) * 0.8 }}>
          바깥을 누르거나 Esc로 닫기
        </p>
      </div>
      {/* 번쩍: 번쩍일 때만 그린다 (혼합 모드 막이 늘 있으면 회전한 게이지와 합성 경계가 네모로 보인다) */}
      {flash > 0.002 && <div className="pointer-events-none absolute inset-0 mix-blend-plus-lighter" style={{ background: "#ffdb9e", opacity: flash }} />}
    </div>,
    document.body,
  );
}

function Chip({ label, value }: { label: string; value: string }) {
  return (
    <span className="flex items-center gap-2 rounded-full border border-white/10 bg-black/40 px-4 py-2">
      <span className="text-sm text-ink2">{label}</span>
      <span className="font-cute text-lg tabular-nums">{value}</span>
    </span>
  );
}

/** 별 하나 (fill 0 · 0.5 · 1) */
function Star({ fill, id }: { fill: number; id: string }) {
  const points = "12,1.5 14.9,8.6 22.5,9.2 16.7,14.1 18.5,21.6 12,17.6 5.5,21.6 7.3,14.1 1.5,9.2 9.1,8.6";
  return (
    <svg viewBox="0 0 24 24" className="size-10" aria-hidden>
      <defs>
        <clipPath id={id}>
          <rect x="0" y="0" width={24 * fill} height="24" />
        </clipPath>
      </defs>
      <polygon points={points} fill="rgba(255,255,255,0.16)" />
      {fill > 0 && (
        <>
          <polygon points={points} fill="rgba(255,204,92,0.35)" transform="translate(12 12) scale(1.18) translate(-12 -12)" clipPath={`url(#${id})`} />
          <polygon points={points} fill="#ffcc5c" clipPath={`url(#${id})`} />
        </>
      )}
    </svg>
  );
}
