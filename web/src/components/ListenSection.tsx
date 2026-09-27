// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 직접 들어 보기: CoNo 의 AI 가 실제로 분리한 결과. 앨범 4장 중 하나를 틀고, 앱과 같은 반주·보컬·원곡 스위치로
// 끊김 없이 바꿔 들어 본다 (세 트랙을 맞춰 동시에 틀고 음량만 바꾼다 — fx/stems.ts).

"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useInView, useOnLeave } from "@/fx/hooks";
import { StemPlayer, audioContext, claimAudio, onAudioClaim, type StemMode } from "@/fx/stems";
import { songUrls, songs, type Song } from "@/lib/songs";
import { Screen, SectionTitle } from "./Screen";
import { PlayPauseIcon } from "./PlayIcons";

const MODES: { mode: StemMode; label: string; hint: string; color: string }[] = [
  { mode: "inst", label: "반주", hint: "AI가 목소리를 지운 반주", color: "#5ee0b8" },
  { mode: "vocal", label: "보컬", hint: "AI가 걸러 낸 목소리만", color: "#ff8fb0" },
  { mode: "mix", label: "원곡", hint: "원래 노래 그대로", color: "#ffcc5c" },
];

type Status = "idle" | "loading" | "playing" | "paused" | "error";

export function ListenSection() {
  const [index, setIndex] = useState(0);
  const [mode, setMode] = useState<StemMode>("mix");
  const [status, setStatus] = useState<Status>("idle");
  const [position, setPosition] = useState(0);
  const playerRef = useRef<StemPlayer | null>(null);
  /** 불러오는 사이 멈추면 도착해도 틀지 않는다 */
  const wantedRef = useRef(false);
  const sectionRef = useRef<HTMLElement>(null);
  const song = songs[index];
  const accent = MODES.find((item) => item.mode === mode)?.color ?? "#ffcc5c";

  const pause = useCallback(() => {
    wantedRef.current = false;
    playerRef.current?.pause();
    setStatus((current) => (current === "playing" ? "paused" : current));
  }, []);

  // 다른 곳(첫 화면·체험)이 소리를 내면 멈춘다. 화면 밖으로 나가도 멈춘다
  useEffect(() => onAudioClaim((owner) => owner !== "listen" && pause()), [pause]);
  useOnLeave(sectionRef, pause, "-20% 0px -20% 0px");
  useEffect(() => () => playerRef.current?.dispose(), []);

  // 재생 위치 (파형 진행 표시)
  useEffect(() => {
    if (status !== "playing") return;
    let frame = 0;
    const tick = () => {
      setPosition(playerRef.current?.position ?? 0);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [status]);

  const start = useCallback(
    // withMode: 방금 누른 스위치 값 (setMode 가 아직 반영되기 전이라 인자로 받는다)
    async (next: number, from = 0, withMode: StemMode = mode) => {
      claimAudio("listen");
      wantedRef.current = true;
      const ctx = audioContext();
      void ctx.resume();
      if (!playerRef.current || next !== index) {
        playerRef.current?.dispose();
        playerRef.current = new StemPlayer(ctx, songUrls(songs[next].slug), withMode);
        setIndex(next);
        setPosition(0);
      }
      const player = playerRef.current;
      setStatus("loading");
      try {
        await player.load();
        if (playerRef.current !== player || !wantedRef.current) return; // 기다리는 사이 다른 곡을 골랐거나 멈췄다
        player.setMode(withMode, 0);
        player.play(from);
        setStatus("playing");
      } catch {
        setStatus("error");
      }
    },
    [index, mode],
  );

  const toggle = () => {
    if (status === "playing") pause();
    else void start(index, playerRef.current?.position ?? 0);
  };

  const choose = (next: number) => {
    if (next === index && status === "playing") return;
    void start(next, 0);
  };

  const switchMode = (next: StemMode) => {
    setMode(next);
    playerRef.current?.setMode(next);
    // 멈춰 있으면 바꾼 소리로 바로 들려준다
    if (status !== "playing" && status !== "loading") void start(index, playerRef.current?.position ?? 0, next);
  };

  const seek = (ratio: number) => {
    const player = playerRef.current;
    if (!player?.loaded) return;
    player.seek(ratio * player.duration);
    setPosition(player.position);
  };

  const duration = song.duration;
  const progress = position / duration;
  const playing = status === "playing";

  return (
    <Screen id="listen" innerRef={sectionRef} glow={{ color: `${accent}1f`, x: "65%", y: "50%" }}>
      <div className="grid items-center gap-10 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.5fr)]">
        <div>
          <SectionTitle kicker="LISTEN" title="노래 연습하려면, 원곡에서 가수 목소리만 들어보세요" align="left">
            CoNo의 AI가 실제로 분리한 소리예요. 재생하고 <b className="text-ink">반주 · 보컬 · 원곡</b>을 눌러 바꿔 보세요.
          </SectionTitle>
          <ul className="mt-6 space-y-1.5">
            {songs.map((item, itemIndex) => {
              const active = itemIndex === index;
              return (
                <li key={item.slug}>
                  <button
                    type="button"
                    onClick={() => choose(itemIndex)}
                    className={`flex w-full items-center gap-3.5 rounded-2xl border px-3 py-2 text-left transition ${
                      active ? "border-white/25 bg-white/[0.07]" : "border-transparent hover:bg-white/[0.04]"
                    }`}
                  >
                    <Cover song={item} size={36} spinning={false} />
                    <span className="min-w-0 flex-1 truncate font-cute text-lg">{item.title}</span>
                    {active && playing && <Equalizer color={accent} />}
                  </button>
                </li>
              );
            })}
          </ul>
        </div>

        <Reveal>
          <div className="relative overflow-hidden rounded-[32px] border border-white/10 bg-gradient-to-b from-white/[0.07] to-white/[0.02] p-6 shadow-[0_30px_100px_-30px_rgba(0,0,0,0.8)] sm:p-8">
            <div className="flex items-center gap-5 sm:gap-6">
              <span className="sm:hidden">
                <Cover song={song} size={96} spinning={playing} glow={accent} />
              </span>
              <span className="hidden sm:block">
                <Cover song={song} size={148} spinning={playing} glow={accent} />
              </span>
              <div className="min-w-0">
                <p className="text-sm text-faint">지금 듣는 곡</p>
                <p className="mt-1 truncate font-cute text-3xl">{song.title}</p>
                <p className="mt-3 text-sm" style={{ color: accent }}>
                  ● {MODES.find((item) => item.mode === mode)?.hint}
                </p>
              </div>
            </div>

            <Waveform peaks={song.peaks} progress={progress} color={accent} onSeek={seek} />
            <div className="mt-2 flex justify-between text-xs tabular-nums text-faint">
              <span>{formatTime(position)}</span>
              <span>{formatTime(duration)}</span>
            </div>

            <div className="mt-5 flex flex-wrap items-center gap-4 sm:gap-5">
              <button
                type="button"
                onClick={toggle}
                aria-label={playing ? "일시정지" : "재생"}
                className="grid size-16 shrink-0 place-items-center rounded-full bg-ink text-2xl text-night shadow-[0_0_30px_rgba(237,240,255,0.25)] transition hover:scale-105"
              >
                {status === "loading" ? <span className="size-6 animate-spin rounded-full border-[3px] border-night/30 border-t-night" /> : <PlayPauseIcon playing={playing} size={26} />}
              </button>
              <div className="flex rounded-full bg-black/35 p-1.5" role="radiogroup" aria-label="들을 소리">
                {MODES.map((item) => {
                  const selected = item.mode === mode;
                  return (
                    <button
                      key={item.mode}
                      type="button"
                      role="radio"
                      aria-checked={selected}
                      onClick={() => switchMode(item.mode)}
                      className={`rounded-full px-4 py-2.5 font-cute text-lg transition sm:px-5 ${selected ? "text-night" : "text-ink2 hover:text-ink"}`}
                      style={selected ? { background: item.color, boxShadow: `0 0 24px ${item.color}88` } : undefined}
                    >
                      {item.label}
                    </button>
                  );
                })}
              </div>
            </div>
            {status === "error" && <p className="mt-4 text-sm text-stop">소리를 불러오지 못했어요. 잠시 뒤 다시 눌러 주세요.</p>}
            {status === "idle" && <p className="mt-4 text-sm text-faint">▶ 를 누르고, 노래가 나오는 중에 반주를 눌러 보세요.</p>}
          </div>
        </Reveal>
      </div>
    </Screen>
  );
}

function Reveal({ children }: { children: React.ReactNode }) {
  const [ref, inView] = useInView<HTMLDivElement>({ once: true, margin: "0px 0px 80px 0px" });
  return (
    <div ref={ref} className={`reveal ${inView ? "in" : ""}`}>
      {children}
    </div>
  );
}

/** 레코드판 모양 표지: 곡 색으로 만든 원판, 재생 중이면 돈다 */
function Cover({ song, size, spinning, glow }: { song: Song; size: number; spinning: boolean; glow?: string }) {
  const [a, b, c] = song.colors;
  return (
    <span
      className="relative grid shrink-0 place-items-center rounded-full"
      style={{
        width: size,
        height: size,
        background: `conic-gradient(from 30deg, ${a}, ${b}, ${c}, ${a})`,
        boxShadow: glow ? `0 0 ${size / 3}px ${glow}55` : undefined,
        animation: "spin-slow 6s linear infinite",
        animationPlayState: spinning ? "running" : "paused",
      }}
      aria-hidden
    >
      {/* 홈 결 */}
      <span className="absolute inset-[8%] rounded-full" style={{ background: "repeating-radial-gradient(circle, rgba(0,0,0,0.16) 0 1px, transparent 1px 4px)" }} />
      <span className="absolute inset-0 rounded-full bg-[radial-gradient(circle_at_30%_25%,rgba(255,255,255,0.35),transparent_45%)]" />
      <span className="relative rounded-full bg-night" style={{ width: size * 0.18, height: size * 0.18, boxShadow: "0 0 0 3px rgba(255,255,255,0.15)" }} />
    </span>
  );
}

/** 파형: 지나간 부분은 밝게, 눌러서 이동. SVG 라 폭에 맞춰 늘고 준다 (막대 120개를 div 로 두면 좁은 화면에서 간격만으로 넘친다) */
function Waveform({ peaks, progress, color, onSeek }: { peaks: number[]; progress: number; color: string; onSeek: (ratio: number) => void }) {
  const height = 40;
  return (
    <svg
      viewBox={`0 0 ${peaks.length} ${height}`}
      preserveAspectRatio="none"
      className="mt-7 block h-20 w-full cursor-pointer outline-none"
      onClick={(event) => {
        const rect = event.currentTarget.getBoundingClientRect();
        onSeek((event.clientX - rect.left) / rect.width);
      }}
      role="slider"
      aria-label="재생 위치"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(progress * 100)}
      tabIndex={0}
      onKeyDown={(event) => {
        if (event.key === "ArrowRight") onSeek(Math.min(1, progress + 0.05));
        if (event.key === "ArrowLeft") onSeek(Math.max(0, progress - 0.05));
      }}
    >
      {peaks.map((peak, index) => {
        const bar = Math.max(0.08, peak) * height;
        return (
          <rect
            key={index}
            x={index + 0.2}
            y={(height - bar) / 2}
            width={0.6}
            height={bar}
            rx={0.3}
            style={{ fill: index / peaks.length <= progress ? color : "rgba(255,255,255,0.16)", transition: "fill 0.3s" }}
          />
        );
      })}
    </svg>
  );
}

function Equalizer({ color }: { color: string }) {
  return (
    <span className="flex h-4 items-end gap-0.5" aria-hidden>
      {[0, 1, 2].map((bar) => (
        <span key={bar} className="w-1 rounded-full" style={{ background: color, height: "100%", animation: `floaty ${0.5 + bar * 0.15}s ease-in-out infinite`, transformOrigin: "bottom" }} />
      ))}
    </span>
  );
}

function formatTime(seconds: number) {
  const total = Math.max(0, Math.floor(seconds));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
