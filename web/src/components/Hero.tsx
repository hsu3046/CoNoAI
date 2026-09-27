// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 첫 화면: 평범한 음악 앱 창의 ▶ 를 누르면 불이 꺼지고, 네온사인 "코인 노래방" 이 켜졌다가
// "No!" 도장이 찍히고 "집에서 나만의 노래방" 으로 바뀐다. 누르지 않아도 몇 초 뒤 저절로.

"use client";

import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import { useInView } from "@/fx/hooks";
import { release } from "@/lib/release";
import { CONTAINER } from "./Screen";

type Phase = "idle" | "dark" | "sign" | "stamp" | "party";

const SEQUENCE: [Phase, number][] = [
  ["dark", 0],
  ["sign", 380],
  ["stamp", 1900],
  ["party", 2600],
];

export function Hero() {
  const [phase, setPhase] = useState<Phase>("idle");
  const timers = useRef<number[]>([]);
  // 화면 밖으로 나가면 반복 애니메이션(미러볼·스포트라이트·음표)을 멈춘다
  const [sectionRef, inView] = useInView<HTMLElement>({ margin: "100px" });

  // 한 번 시작하면 다시 돌리지 않는다 — 누른 뒤 5초 자동 시작이 또 울려 간판이 꺼졌다 켜지던 문제
  const started = useRef(false);
  const play = useCallback(async () => {
    if (started.current) return;
    started.current = true;
    // 네온사인 글꼴이 도착한 뒤 시작 (도중에 글꼴이 바뀌면 그려지던 윤곽이 튄다). 느린 망이면 1.2초까지만 기다린다
    const family = getComputedStyle(document.documentElement).getPropertyValue("--font-black-han-sans").trim();
    if (family) {
      await Promise.race([document.fonts.load(`170px ${family}`, "코인 노래방 집에서 나만의"), new Promise((resolve) => window.setTimeout(resolve, 1200))]).catch(() => undefined);
    }
    timers.current = SEQUENCE.map(([next, delay]) => window.setTimeout(() => setPhase(next), delay));
  }, []);
  const clearTimers = useCallback(() => timers.current.forEach(window.clearTimeout), []);

  // 빨리 감기: 연출이 끝나기 전에 스크롤하면 남은 단계를 짧은 간격으로 이어 붙인다 (약 0.9초)
  const [fast, setFast] = useState(false);
  const phaseRef = useRef<Phase>("idle");
  useEffect(() => {
    phaseRef.current = phase;
  }, [phase]);
  const fastForward = useCallback(() => {
    clearTimers();
    started.current = true;
    setFast(true);
    const current = SEQUENCE.findIndex(([p]) => p === phaseRef.current);
    const remaining = SEQUENCE.slice(current + 1);
    timers.current = remaining.map(([next], index) => window.setTimeout(() => setPhase(next), 40 + index * 200));
    // 마지막 단계 뒤 네온이 다 켜질 때까지
    return 40 + Math.max(0, remaining.length - 1) * 200 + 380;
  }, [clearTimers]);

  // 연출이 끝나기 전에 스크롤하면: 딱 한 번, 스크롤을 잠깐 붙잡고 빨리 감은 뒤 스토리로 부드럽게 내려간다.
  // 스크롤바를 끌어 붙잡을 수 없으면 바로 마지막 장면으로.
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let intercepted = false;
    let holding = false;
    const keys = new Set([" ", "ArrowDown", "PageDown", "End"]);
    const cleanup = () => {
      window.removeEventListener("wheel", onIntent);
      window.removeEventListener("touchmove", onIntent);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("scroll", onScroll);
    };
    const onIntent = (event: Event) => {
      if (holding) {
        event.preventDefault();
        return;
      }
      if (intercepted || phaseRef.current === "party" || window.scrollY > 40) return;
      if (event instanceof WheelEvent && event.deltaY <= 0) return; // 위로 굴리면 그대로
      intercepted = true;
      holding = true;
      event.preventDefault();
      const settle = fastForward();
      window.setTimeout(() => {
        holding = false;
        cleanup();
        document.getElementById("story")?.scrollIntoView({ behavior: "smooth" });
      }, settle + 150);
    };
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target?.closest("input, textarea, button, a, [contenteditable]")) return;
      if (keys.has(event.key)) onIntent(event);
    };
    const onScroll = () => {
      if (intercepted || phaseRef.current === "party" || window.scrollY <= 40) return;
      intercepted = true;
      clearTimers();
      started.current = true;
      setPhase("party");
      cleanup();
    };
    window.addEventListener("wheel", onIntent, { passive: false });
    window.addEventListener("touchmove", onIntent, { passive: false });
    window.addEventListener("keydown", onKey);
    window.addEventListener("scroll", onScroll, { passive: true });
    return cleanup;
  }, [fastForward, clearTimers]);

  // 가만있어도 5초 뒤 시작 (움직임 줄이기면 바로 마지막 장면)
  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const auto = window.setTimeout(
      reduced
        ? () => {
            started.current = true;
            setPhase("party");
          }
        : () => void play(),
      reduced ? 0 : 5000,
    );
    return () => {
      window.clearTimeout(auto);
      clearTimers();
    };
  }, [play, clearTimers]);

  const lit = phase !== "idle";
  const at = (target: Phase) => SEQUENCE.findIndex(([p]) => p === phase) >= SEQUENCE.findIndex(([p]) => p === target);

  return (
    <section
      ref={sectionRef}
      className={`relative isolate flex min-h-[max(100dvh,720px)] snap-start flex-col items-center justify-center overflow-hidden px-4 pb-16 pt-28 ${inView ? "" : "anim-paused"}`}
    >
      {/* 방: 오후 햇살 → 소등 → 노래방 */}
      <div
        className="absolute inset-0 -z-20 transition-[background] duration-700"
        style={{
          background: lit
            ? "radial-gradient(ellipse at 50% 20%, #2a1147 0%, #170d29 45%, #0b0d1a 100%)"
            : "radial-gradient(ellipse at 70% 10%, #3d3350 0%, #1d1b2e 55%, #11121f 100%)",
        }}
      />
      {/* 간판이 벽을 비춘다: 켜지는 순서대로 분홍 → 민트 빛이 번진다 */}
      <div
        className="pointer-events-none absolute inset-0 -z-10 transition-opacity duration-1000"
        style={{
          opacity: at("sign") ? 1 : 0,
          background: "radial-gradient(ellipse 48% 30% at 50% 36%, rgba(255,143,176,0.16), transparent 70%)",
        }}
        aria-hidden
      />
      <div
        className="pointer-events-none absolute inset-0 -z-10 transition-opacity duration-1000"
        style={{
          opacity: at("party") ? 1 : 0,
          background: "radial-gradient(ellipse 50% 22% at 50% 52%, rgba(94,224,184,0.12), transparent 70%)",
        }}
        aria-hidden
      />
      <Spotlights on={at("party")} />
      <MirrorBallLights on={at("party")} />
      <FloatingNotes on={at("party")} />
      {/* 바닥은 어둡게 가라앉혀 방의 깊이를 */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-1/3 bg-gradient-to-t from-night via-night/60 to-transparent" aria-hidden />

      {/* 네온사인 */}
      <div className="relative z-10 w-full max-w-5xl text-center" aria-live="polite">
        <p
          className={`mb-4 font-cute text-lg text-ink2 transition-opacity duration-500 sm:text-xl ${lit ? "opacity-0" : "opacity-100"}`}
        >
          평범한 오후, 늘 듣던 노래…
        </p>
        <h1 className="sr-only">코인 노래방 No! 집에서 나만의 노래방 — CoNo</h1>
        <div className={`relative mx-auto transition-all duration-500 ${lit ? "h-auto opacity-100" : "pointer-events-none h-0 opacity-0"}`} aria-hidden>
          <NeonTube text="코인 노래방" color="#ff8fb0" drawn={at("sign")} fast={fast} />
          {/* "No!": 같은 네온관, 빨간 빛 — 간판 오른쪽 위에 따로 걸린 작은 간판처럼 */}
          <span
            className={`absolute right-[-1%] top-[-24%] font-display text-[clamp(40px,8.4vw,104px)] leading-none ${at("stamp") ? "flicker-once" : ""}`}
            style={{
              opacity: at("stamp") ? 1 : 0,
              color: "#fff0f0",
              transform: "rotate(-12deg)",
              transition: "opacity 0.15s",
              textShadow: "0 0 2px #fff, 0 0 8px #ff5a5a, 0 0 18px #ff5a5a, 0 0 42px #ff3b3b, 0 0 80px rgba(255,59,59,0.55)",
            }}
          >
            No!
          </span>
          <p
            className={`neon neon-mint mt-2 font-display text-[clamp(34px,7.4vw,92px)] leading-tight transition-opacity duration-300 ${at("party") ? "flicker-once opacity-100" : "opacity-0"}`}
          >
            집에서 나만의 노래방
          </p>
        </div>

        {/* 음악 앱 창: 처음엔 가운데, 불이 꺼지면 작아져 아래로 */}
        <div
          className={`mx-auto transition-all duration-700 ease-out ${
            lit ? "mt-6 w-[min(360px,90vw)] scale-90 opacity-80" : "mt-2 w-[min(460px,92vw)]"
          }`}
        >
          <MusicAppCard playing={lit} onPlay={() => void play()} />
        </div>

        <div
          className={`mt-8 flex flex-col items-center gap-5 transition-all duration-700 ${at("party") ? "translate-y-0 opacity-100" : "pointer-events-none translate-y-6 opacity-0"}`}
        >
          <p className="max-w-2xl text-balance text-base leading-relaxed text-ink2 sm:text-lg">
            Apple Music · YouTube Music · Spotify… Mac 에서 나오는 <b className="text-ink">그 노래 그대로</b>.
            <br className="hidden sm:block" />
            목소리는 AI 가 지우고, 가사 · 음정 바 · 채점은 CoNo 가.
          </p>
          <div className="flex flex-wrap items-center justify-center gap-3">
            <a
              href="#download"
              className="group relative rounded-full bg-gold px-7 py-3.5 font-cute text-lg text-night shadow-[0_0_30px_rgba(255,204,92,0.55)] transition hover:scale-105"
            >
              Mac 용 무료 다운로드
              <span className="ml-2 text-sm opacity-70">v{release.version}</span>
            </a>
            <a
              href="#try"
              className="rounded-full border border-white/20 bg-white/5 px-7 py-3.5 font-cute text-lg backdrop-blur transition hover:border-pink hover:text-pink"
            >
              🎤 브라우저에서 불러보기
            </a>
          </div>
        </div>
      </div>

      <a
        href="#story"
        aria-label="아래로"
        className={`absolute bottom-6 left-1/2 -translate-x-1/2 text-2xl text-faint transition-opacity ${at("party") ? "animate-bounce opacity-100" : "opacity-0"}`}
      >
        ⌄
      </a>
    </section>
  );
}

/** 네온관: 글자 윤곽이 그려진 뒤 빛이 들어온다 */
function NeonTube({ text, color, drawn, fast }: { text: string; color: string; drawn: boolean; fast: boolean }) {
  return (
    <svg viewBox="0 0 1000 190" className="mx-auto w-full max-w-4xl overflow-visible" role="presentation">
      <defs>
        <filter id="neon-glow" x="-20%" y="-50%" width="140%" height="200%">
          <feGaussianBlur stdDeviation="6" result="blur" />
          <feMerge>
            <feMergeNode in="blur" />
            <feMergeNode in="blur" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>
      <text
        x="500"
        y="150"
        textAnchor="middle"
        className="font-display"
        fontSize="170"
        fill={drawn ? "#fff" : "transparent"}
        stroke={color}
        strokeWidth="5"
        strokeLinejoin="round"
        filter="url(#neon-glow)"
        style={{
          strokeDasharray: 2600,
          strokeDashoffset: drawn ? 0 : 2600,
          transition: fast ? "stroke-dashoffset 0.45s ease-out, fill 0.2s ease 0.35s" : "stroke-dashoffset 1.3s ease-in-out, fill 0.4s ease 1.1s",
          paintOrder: "stroke",
        }}
      >
        {text}
      </text>
    </svg>
  );
}

function MusicAppCard({ playing, onPlay }: { playing: boolean; onPlay: () => void }) {
  return (
    <div className="rounded-3xl border border-white/10 bg-white/[0.06] p-4 text-left shadow-2xl backdrop-blur-xl">
      <div className="mb-3 flex gap-1.5">
        <span className="size-3 rounded-full bg-[#ff5f57]" />
        <span className="size-3 rounded-full bg-[#febc2e]" />
        <span className="size-3 rounded-full bg-[#28c840]" />
      </div>
      <div className="flex items-center gap-4">
        <div className="relative size-20 shrink-0 overflow-hidden rounded-2xl bg-[conic-gradient(from_200deg,#ff8fb0,#b88cff,#5cc7ff,#5ee0b8,#ffcc5c,#ff8fb0)]">
          <div className={`absolute inset-0 bg-black/20 ${playing ? "animate-[spin-slow_6s_linear_infinite]" : ""}`} />
        </div>
        <div className="min-w-0 flex-1">
          <p className="truncate font-bold">늘 듣던 그 노래</p>
          <p className="truncate text-sm text-ink2">좋아하는 가수</p>
          <div className="mt-3 flex h-6 items-end gap-[3px]" aria-hidden>
            {Array.from({ length: 26 }, (_, index) => (
              <span
                key={index}
                className="w-1 rounded-full bg-gradient-to-t from-pink to-gold"
                style={{
                  height: playing ? `${30 + ((index * 37) % 70)}%` : "18%",
                  transition: `height ${0.25 + (index % 5) * 0.08}s ease`,
                  animation: playing ? `floaty ${0.6 + (index % 4) * 0.15}s ease-in-out infinite` : undefined,
                }}
              />
            ))}
          </div>
        </div>
        <button
          type="button"
          onClick={onPlay}
          aria-label="재생 — CoNo 켜기"
          className="relative grid size-14 shrink-0 place-items-center rounded-full bg-ink text-night transition hover:scale-110"
        >
          {!playing && <span className="absolute inset-0 animate-ping rounded-full bg-ink/40" />}
          <span className="relative text-xl">{playing ? "❚❚" : "▶"}</span>
        </button>
      </div>
      {!playing && <p className="mt-3 text-center font-cute text-sm text-gold">▶ 를 눌러 보세요</p>}
    </div>
  );
}

function Spotlights({ on }: { on: boolean }) {
  return (
    <div className={`pointer-events-none absolute inset-0 -z-10 transition-opacity duration-1000 ${on ? "opacity-100" : "opacity-0"}`} aria-hidden>
      {[
        { left: "12%", color: "255,143,176", strength: 0.24, delay: "0s" },
        { left: "50%", color: "92,199,255", strength: 0.18, delay: "-2s" },
        { left: "88%", color: "94,224,184", strength: 0.22, delay: "-4s" },
      ].map((beam) => (
        <Beam key={beam.left} {...beam} />
      ))}
    </div>
  );
}

/** 빛줄기: 작은 캔버스에 한 번만 그리고 크게 늘려 돌린다.
 *  (화면보다 큰 그라데이션을 레티나 해상도로 돌리면 프레임이 튄다 — 빛은 흐릿해서 늘려도 티가 안 난다) */
function Beam({ left, color, strength, delay }: { left: string; color: string; strength: number; delay: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const { width, height } = canvas;
    ctx.clearRect(0, 0, width, height);
    // 위 꼭짓점에서 아래로 퍼지는 빛: 가로는 가운데가 밝고, 세로는 아래로 갈수록 옅게
    for (let y = 0; y < height; y++) {
      const spread = 1 + (y / height) * (width / 2 - 1);
      const fade = 1 - (y / height) * 0.55;
      const gradient = ctx.createLinearGradient(width / 2 - spread, 0, width / 2 + spread, 0);
      gradient.addColorStop(0, `rgba(${color},0)`);
      gradient.addColorStop(0.5, `rgba(${color},${strength * fade})`);
      gradient.addColorStop(1, `rgba(${color},0)`);
      ctx.fillStyle = gradient;
      ctx.fillRect(width / 2 - spread, y, spread * 2, 1);
    }
  }, [color, strength]);
  return (
    <canvas
      ref={ref}
      width={64}
      height={220}
      className="absolute -top-24 h-[140%] w-[34vw] origin-top will-change-transform"
      style={{ left, marginLeft: "-17vw", animation: `sweep 7s ease-in-out ${delay} infinite` }}
    />
  );
}

/** 미러볼이 벽에 뿌리는 빛 조각: 공은 보이지 않고, 부드러운 빛 점들이 천천히 벽을 지나간다 */
function MirrorBallLights({ on }: { on: boolean }) {
  const colors = ["255,255,255", "255,143,176", "92,199,255", "94,224,184", "255,204,92"];
  return (
    <div className={`pointer-events-none absolute inset-0 -z-10 overflow-hidden transition-opacity duration-[1500ms] ${on ? "opacity-100" : "opacity-0"}`} aria-hidden>
      {Array.from({ length: 22 }, (_, index) => {
        const size = 6 + ((index * 7) % 5) * 3;
        const color = colors[index % colors.length];
        return (
          <span
            key={index}
            className="absolute rounded-full will-change-transform"
            style={{
              left: `${(index * 37) % 100}%`,
              top: `${(index * 53) % 70}%`,
              width: size,
              height: size,
              background: `radial-gradient(circle, rgba(${color},0.9), rgba(${color},0.25) 45%, transparent 70%)`,
              animation: `drift ${14 + (index % 6) * 3}s linear ${-index * 1.7}s infinite, twinkle ${2.4 + (index % 4) * 0.7}s ease-in-out ${index * 0.3}s infinite`,
            }}
          />
        );
      })}
    </div>
  );
}

function FloatingNotes({ on }: { on: boolean }) {
  const notes = ["♪", "♫", "♬", "♩", "♪", "♫"];
  return (
    <div className={`pointer-events-none absolute inset-0 -z-10 transition-opacity duration-1000 ${on ? "opacity-100" : "opacity-0"}`} aria-hidden>
      {notes.map((note, index) => (
        <span
          key={index}
          className="floaty absolute font-display text-4xl"
          style={
            {
              left: `${8 + index * 16}%`,
              top: `${20 + ((index * 37) % 55)}%`,
              color: ["#ff8fb0", "#5ee0b8", "#ffcc5c", "#5cc7ff", "#b88cff", "#ff8fb0"][index],
              textShadow: "0 0 18px currentColor",
              animationDelay: `${index * -0.8}s`,
              "--r": `${index % 2 ? -12 : 10}deg`,
              opacity: 0.55,
            } as React.CSSProperties
          }
        >
          {note}
        </span>
      ))}
    </div>
  );
}

export function SiteHeader() {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const update = () => setScrolled(window.scrollY > 24);
    update();
    window.addEventListener("scroll", update, { passive: true });
    return () => window.removeEventListener("scroll", update);
  }, []);
  return (
    <header
      className={`fixed inset-x-0 top-0 z-50 transition-colors duration-300 ${scrolled ? "border-b border-white/10 bg-night/80 backdrop-blur-md" : ""}`}
    >
      <nav className={`${CONTAINER} flex h-16 items-center justify-between`}>
        <a href="#" className="flex items-center gap-2.5">
          <Image src="/logo.png" alt="" width={34} height={34} className="drop-shadow-[0_0_10px_rgba(94,224,184,0.45)]" />
          <span className="font-display text-xl tracking-wide">CoNo</span>
        </a>
        <div className="flex items-center gap-1 text-sm sm:gap-2">
          {[
            ["#try", "불러보기"],
            ["#how", "사용법"],
            ["#faq", "FAQ"],
          ].map(([href, label]) => (
            <a key={href} href={href} className="hidden rounded-full px-3 py-2 text-ink2 transition hover:text-ink sm:block">
              {label}
            </a>
          ))}
          <a href="#download" className="rounded-full bg-white/10 px-4 py-2 font-cute text-base transition hover:bg-gold hover:text-night">
            다운로드
          </a>
        </div>
      </nav>
    </header>
  );
}
