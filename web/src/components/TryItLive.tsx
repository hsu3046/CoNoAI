// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 브라우저에서 바로 불러보기: 체험곡 반주를 틀고 마이크 음정을 음정 바에 금색 선으로 겹쳐 그린다.
// 판정은 앱과 같다 — 옥타브 무관 ±50센트, 반응 여유 ±0.12초, 음표별 60% 면 만점. 끝나면 점수 연출.
// 목소리는 브라우저 안에서만 음정을 재고 어디에도 보내거나 저장하지 않는다.

"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { playBacking, type Backing } from "@/fx/backing";
import { canvasFonts, fitCanvas, useInView } from "@/fx/hooks";
import { loadSfx } from "@/fx/sfx";
import { BEAT_SECONDS, COUNT_IN_BEATS, SONG_SECONDS, hzToMidi, lyricLines, melody, type MelodyNote } from "@/lib/melody";
import { detectPitch, foldedOffset, scoreSong, type NoteTally, type SongScore } from "@/lib/pitch";
import { ScoreShow } from "./ScoreShow";

type Phase = "idle" | "starting" | "running" | "done" | "error";

type TrailPoint = { t: number; midi: number | null; hit: boolean };

const TOLERANCE = 0.5;
const REACTION = 0.12;
const VIEW_LOW = 55; // G3
const VIEW_HIGH = 76; // E5
const PAST = 1.6;
const FUTURE = 4.2;

export function TryItLive() {
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [guide, setGuide] = useState(true);
  const [result, setResult] = useState<SongScore | null>(null);
  const [sectionRef, visible] = useInView<HTMLElement>({ margin: "200px" });
  const [audio, setAudio] = useState<AudioContext | null>(null);
  const visibleRef = useRef(true);
  useEffect(() => {
    visibleRef.current = visible;
  }, [visible]);

  const canvasRef = useRef<HTMLCanvasElement>(null);
  const audioRef = useRef<AudioContext | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const backingRef = useRef<Backing | null>(null);
  const frameRef = useRef(0);

  const cleanup = useCallback(() => {
    cancelAnimationFrame(frameRef.current);
    backingRef.current?.stop();
    backingRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
  }, []);

  useEffect(() => () => cleanup(), [cleanup]);

  const draw = useCallback((heard: number, trail: TrailPoint[], tallies: NoteTally[]) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const { width, height, ctx } = fitCanvas(canvas);
    if (!ctx) return;
    drawStage(ctx, width, height, heard, trail, tallies);
  }, []);

  const run = useCallback((ctx: AudioContext, analyser: AnalyserNode, backing: Backing) => {
    const buffer = new Float32Array(analyser.fftSize);
    const trail: TrailPoint[] = [];
    const tallies: NoteTally[] = melody.map((note) => ({ frames: 0, hits: 0, seconds: note.beats * BEAT_SECONDS }));
    const noise: number[] = [];
    let lastRef: number | null = null;

    const loop = () => {
      frameRef.current = requestAnimationFrame(loop);
      // 화면 밖으로 나가면 멈춘다
      if (!visibleRef.current) {
        cleanup();
        setPhase("idle");
        return;
      }
      const latency = (ctx.outputLatency || 0) + (ctx.baseLatency || 0);
      // 지금 귀에 들리는 곡 위치 (카운트 중엔 음수)
      const heard = ctx.currentTime - latency - backing.songStart;
      // 마이크 분석 창의 가운데 = 약 20 ms 전에 부른 소리
      const sungAt = heard - analyser.fftSize / 2 / ctx.sampleRate;

      analyser.getFloatTimeDomainData(buffer);
      const reading = detectPitch(buffer, ctx.sampleRate);
      const rms = reading?.rms ?? rootMeanSquare(buffer);
      // 카운트 동안 잡음 바닥을 잰다 (스피커 누설 포함)
      if (heard < 0) {
        noise.push(rms);
        if (noise.length > 200) noise.shift();
      }
      const floor = median(noise);
      const voiced = reading && reading.clarity > 0.82 && rms > Math.max(0.008, floor * 2.5);

      if (heard >= -0.2 && heard <= SONG_SECONDS + 0.3) {
        let point: TrailPoint = { t: sungAt, midi: null, hit: false };
        if (voiced && reading) {
          const sung = hzToMidi(reading.hz);
          const match = nearestNote(sung, sungAt);
          if (match) {
            lastRef = match.note.midi;
            point = { t: sungAt, midi: match.note.midi + match.offset, hit: Math.abs(match.offset) <= TOLERANCE };
          } else {
            const reference = lastRef ?? 64;
            point = { t: sungAt, midi: reference + foldedOffset(sung, reference), hit: false };
          }
        }
        trail.push(point);
        // 음표별 집계: 그 순간 불러야 할 음표
        const index = melody.findIndex((note) => sungAt >= note.beat * BEAT_SECONDS && sungAt < (note.beat + note.beats) * BEAT_SECONDS);
        if (index >= 0) {
          tallies[index].frames += 1;
          if (point.hit) tallies[index].hits += 1;
        }
      }
      draw(heard, trail, tallies);

      if (heard > SONG_SECONDS + 0.6) {
        cancelAnimationFrame(frameRef.current);
        streamRef.current?.getTracks().forEach((track) => track.stop());
        streamRef.current = null;
        backingRef.current = null;
        setResult(scoreSong(tallies));
        setPhase("done");
      }
    };
    frameRef.current = requestAnimationFrame(loop);
  }, [draw, cleanup]);

  const start = useCallback(async () => {
    setError(null);
    setResult(null);
    setPhase("starting");
    try {
      const ctx = audioRef.current ?? new AudioContext();
      audioRef.current = ctx;
      setAudio(ctx);
      await ctx.resume();
      void loadSfx(ctx); // 점수 연출 소리를 미리 받아 둔다
      // 반향 제거는 켠다: 스피커로 나간 반주를 브라우저가 마이크에서 빼 준다. 자동 게인·잡음 억제는 노래를 뭉개서 끈다
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false },
      });
      streamRef.current = stream;
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 2048;
      const source = ctx.createMediaStreamSource(stream);
      const highpass = ctx.createBiquadFilter();
      highpass.type = "highpass";
      highpass.frequency.value = 80;
      source.connect(highpass).connect(analyser);

      const backing = playBacking(ctx, { guide });
      backingRef.current = backing;
      setPhase("running");
      run(ctx, analyser, backing);
    } catch (caught) {
      cleanup();
      const name = caught instanceof DOMException ? caught.name : "";
      setError(
        name === "NotAllowedError"
          ? "마이크 권한이 필요해요. 주소창 옆 🔒 에서 마이크를 허용한 뒤 다시 눌러 주세요."
          : name === "NotFoundError"
            ? "마이크를 찾지 못했어요. 마이크를 연결하고 다시 시도해 주세요."
            : "시작하지 못했어요. 다른 브라우저(Chrome·Safari)로 시도해 주세요.",
      );
      setPhase("error");
    }
  }, [guide, cleanup, run]);

  // 멈춰 있을 때 보여줄 첫 화면
  useEffect(() => {
    if (phase === "running") return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const paint = () => {
      const { width, height, ctx } = fitCanvas(canvas);
      if (ctx) drawStage(ctx, width, height, -COUNT_IN_BEATS * BEAT_SECONDS - 0.5, [], melody.map(() => ({ frames: 0, hits: 0, seconds: 0 })));
    };
    paint();
    window.addEventListener("resize", paint);
    return () => window.removeEventListener("resize", paint);
  }, [phase]);

  return (
    <section id="try" ref={sectionRef} className="relative px-4 py-24 sm:py-32">
      <div className="mx-auto max-w-5xl">
        <SectionTitle kicker="TRY IT NOW" title="설치 전에, 지금 여기서 불러 보세요" />
        <p className="mx-auto mt-4 max-w-2xl text-center text-ink2">
          CoNo 가 직접 만든 20초짜리 곡 <b className="text-ink">〈우리 집 무대〉</b>. 마이크를 허용하고 금색 선을 음표 위에 올려 보세요.
          높든 낮든 옥타브는 상관없어요. 목소리는 이 브라우저 밖으로 나가지 않아요.
        </p>

        <div className="relative mt-10 overflow-hidden rounded-[28px] border border-white/10 bg-gradient-to-b from-[#1b1030] to-[#0e0f1f] p-3 shadow-[0_30px_120px_-20px_rgba(255,143,176,0.35)] sm:p-5">
          <canvas ref={canvasRef} className="block h-[360px] w-full sm:h-[440px]" role="img" aria-label="체험곡 음정 바와 가사" />

          {phase !== "running" && (
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 bg-night/55 px-6 text-center backdrop-blur-[2px]">
              <button
                type="button"
                onClick={start}
                disabled={phase === "starting"}
                className="group relative rounded-full bg-pink px-9 py-4 font-cute text-2xl text-night shadow-[0_0_40px_rgba(255,143,176,0.7)] transition hover:scale-105 disabled:opacity-60"
              >
                <span className="absolute inset-0 -z-10 animate-ping rounded-full bg-pink/40" />
                {phase === "starting" ? "마이크 여는 중…" : phase === "done" || phase === "error" ? "🎤 다시 불러보기" : "🎤 마이크 켜고 시작"}
              </button>
              <label className="flex cursor-pointer items-center gap-2 text-sm text-ink2">
                <input type="checkbox" checked={guide} onChange={(event) => setGuide(event.target.checked)} className="size-4 accent-pink" />
                가이드 멜로디 같이 듣기
              </label>
              <p className="text-xs text-faint">이어폰을 끼면 더 정확해요 · 스피커도 괜찮아요 (브라우저가 반주를 걸러 줘요)</p>
              {error && <p className="max-w-md rounded-xl bg-stop/15 px-4 py-2 text-sm text-stop">{error}</p>}
            </div>
          )}
        </div>
      </div>

      {phase === "done" && result && (
        <ScoreShow
          result={result}
          audio={audio}
          onClose={() => setPhase("idle")}
          onRetry={() => {
            setPhase("idle");
            void start();
          }}
        />
      )}
    </section>
  );
}

export function SectionTitle({ kicker, title }: { kicker: string; title: string }) {
  return (
    <div className="text-center">
      <p className="font-display text-sm tracking-[0.3em] text-pink">{kicker}</p>
      <h2 className="mt-3 text-balance font-cute text-4xl leading-tight sm:text-5xl">{title}</h2>
    </div>
  );
}

/** 부른 음과 (옥타브 무관) 가장 가까운 음표 — 반응 여유 ±REACTION 초 */
function nearestNote(sung: number, t: number): { note: MelodyNote; offset: number } | null {
  let best: { note: MelodyNote; offset: number } | null = null;
  for (const note of melody) {
    const from = note.beat * BEAT_SECONDS - REACTION;
    const to = (note.beat + note.beats) * BEAT_SECONDS + REACTION;
    if (t < from || t > to) continue;
    const offset = foldedOffset(sung, note.midi);
    if (!best || Math.abs(offset) < Math.abs(best.offset)) best = { note, offset };
  }
  return best;
}

function rootMeanSquare(buffer: Float32Array) {
  let sum = 0;
  for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i];
  return Math.sqrt(sum / buffer.length);
}

function median(values: number[]) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

/** 음정 바 · 금색 선 · 가사 · 카운트 · 실시간 점수 */
function drawStage(ctx: CanvasRenderingContext2D, width: number, height: number, heard: number, trail: TrailPoint[], tallies: NoteTally[]) {
  const fonts = canvasFonts();
  ctx.clearRect(0, 0, width, height);
  const lyricSpace = Math.min(110, height * 0.26);
  const top = 12;
  const barHeight = height - lyricSpace - top;
  const rows = VIEW_HIGH - VIEW_LOW + 1;
  const rowHeight = barHeight / rows;
  const x = (t: number) => ((t - (heard - PAST)) / (PAST + FUTURE)) * width;
  const y = (midi: number) => top + barHeight - ((midi - VIEW_LOW + 0.5) / rows) * barHeight;
  const playheadX = x(heard);

  // 격자
  ctx.lineWidth = 1;
  for (let midi = VIEW_LOW; midi <= VIEW_HIGH; midi++) {
    const lineY = y(midi) + rowHeight / 2;
    ctx.strokeStyle = midi % 12 === 0 ? "rgba(255,255,255,0.12)" : "rgba(255,255,255,0.035)";
    ctx.beginPath();
    ctx.moveTo(0, lineY);
    ctx.lineTo(width, lineY);
    ctx.stroke();
    if (midi % 12 === 0) {
      ctx.fillStyle = "#858cb3";
      ctx.font = `11px ${fonts.sans}`;
      ctx.fillText(`C${midi / 12 - 1}`, 8, y(midi) + 4);
    }
  }

  // 지금 맞게 부르는 정도 (최근 0.35초 비율, 부드럽게)
  let recent = 0;
  let recentHits = 0;
  for (let index = trail.length - 1; index >= 0 && heard - trail[index].t < 0.35; index--) {
    recent += 1;
    if (trail[index].hit) recentHits += 1;
  }
  const ratio = recent >= 5 ? recentHits / recent : 0;
  const onPitch = Math.min(1, Math.max(0, (ratio - 0.3) / 0.45));

  // 음표
  melody.forEach((note, index) => {
    const start = note.beat * BEAT_SECONDS;
    const end = (note.beat + note.beats) * BEAT_SECONDS;
    const x1 = x(start);
    const x2 = x(end) - 3;
    if (x2 < 0 || x1 > width) return;
    const noteY = y(note.midi) - rowHeight / 2 + 2;
    const h = Math.max(6, rowHeight - 4);
    const current = start <= heard && heard < end;
    const tally = tallies[index];
    const hit = end < heard && tally.frames > 0 && tally.hits / tally.frames >= 0.5;
    if (current) {
      ctx.fillStyle = `rgba(94,224,184,${0.22 * (1 - onPitch)})`;
      rounded(ctx, x1 - 4, noteY - 4, x2 - x1 + 8, h + 8, h / 2 + 4);
      if (onPitch > 0) {
        const spread = 4 + 5 * onPitch;
        ctx.fillStyle = `rgba(255,204,92,${0.45 * onPitch})`;
        rounded(ctx, x1 - spread, noteY - spread, x2 - x1 + spread * 2, h + spread * 2, h / 2 + spread);
      }
    }
    ctx.fillStyle = end < heard ? (hit ? "rgba(255,204,92,0.65)" : "rgba(255,255,255,0.16)") : current ? "#5ee0b8" : "rgba(255,255,255,0.85)";
    rounded(ctx, x1, noteY, x2 - x1, h, h / 2);
  });

  // 금색 선 (앞뒤 4 프레임 평균으로 굵기)
  ctx.lineCap = "round";
  for (let index = 1; index < trail.length; index++) {
    const a = trail[index - 1];
    const b = trail[index];
    if (a.midi === null || b.midi === null || b.t < heard - PAST || b.t - a.t > 0.08) continue;
    let sum = 0;
    let count = 0;
    for (let k = Math.max(0, index - 4); k <= Math.min(trail.length - 1, index + 4); k++) {
      sum += trail[k].hit ? 1 : 0;
      count += 1;
    }
    const strength = sum / count;
    ctx.strokeStyle = `rgba(255,204,92,${0.55 + 0.45 * strength})`;
    ctx.lineWidth = 2.5 + 2 * strength;
    ctx.beginPath();
    ctx.moveTo(x(a.t), y(a.midi));
    ctx.lineTo(x(b.t), y(b.midi));
    ctx.stroke();
  }
  const head = trail[trail.length - 1];
  if (head && head.midi !== null && heard - head.t < 0.3) {
    ctx.fillStyle = "rgba(255,204,92,0.25)";
    ctx.beginPath();
    ctx.arc(x(head.t), y(head.midi), 14, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "#ffcc5c";
    ctx.beginPath();
    ctx.arc(x(head.t), y(head.midi), 6 + 2 * onPitch, 0, Math.PI * 2);
    ctx.fill();
  }

  // 재생선
  ctx.strokeStyle = "rgba(255,143,176,0.18)";
  ctx.lineWidth = 8;
  ctx.beginPath();
  ctx.moveTo(playheadX, top);
  ctx.lineTo(playheadX, top + barHeight);
  ctx.stroke();
  ctx.strokeStyle = "#ff8fb0";
  ctx.lineWidth = 1.5;
  ctx.stroke();

  // 가사: 지금 줄은 글자마다 색칠, 다음 줄은 흐리게
  const beat = heard / BEAT_SECONDS;
  const lineIndex = Math.max(0, lyricLines.findIndex((line) => beat < line.to));
  const line = lyricLines[lineIndex === -1 ? lyricLines.length - 1 : lineIndex];
  const size = Math.max(26, Math.min(44, width / 16));
  ctx.textAlign = "center";
  ctx.font = `${size}px ${fonts.cute}`;
  const notes = melody.filter((note) => note.beat >= line.from && note.beat < line.to);
  // 낱말 끝(글자 끝 공백)은 한 칸 띄운다
  const widths = notes.map((note) => ctx.measureText(note.syllable.trim()).width + size * (note.syllable.endsWith(" ") ? 0.42 : 0.06));
  const total = widths.reduce((a, b) => a + b, 0);
  let cursor = width / 2 - total / 2;
  const lyricY = top + barHeight + lyricSpace * 0.55;
  notes.forEach((note, index) => {
    const w = widths[index];
    const progress = Math.min(1, Math.max(0, (beat - note.beat) / note.beats));
    const glyph = note.syllable.trim();
    const center = cursor + (w - (note.syllable.endsWith(" ") ? size * 0.36 : 0)) / 2;
    ctx.fillStyle = "rgba(237,240,255,0.35)";
    ctx.fillText(glyph, center, lyricY);
    if (progress > 0) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(cursor, lyricY - size, w * progress, size * 1.5);
      ctx.clip();
      ctx.fillStyle = "#5ee0b8";
      ctx.fillText(glyph, center, lyricY);
      ctx.restore();
    }
    cursor += w;
  });
  const next = lyricLines[lineIndex + 1];
  if (next) {
    ctx.font = `${size * 0.55}px ${fonts.cute}`;
    ctx.fillStyle = "rgba(153,161,199,0.8)";
    ctx.fillText(next.text, width / 2, lyricY + size * 0.95);
  }
  ctx.textAlign = "left";

  // 카운트 3·2·1
  if (heard < 0 && heard > -COUNT_IN_BEATS * BEAT_SECONDS) {
    const count = Math.ceil(-heard / BEAT_SECONDS);
    const within = (-heard % BEAT_SECONDS) / BEAT_SECONDS;
    ctx.save();
    ctx.textAlign = "center";
    ctx.font = `${120 + 40 * within}px ${fonts.display}`;
    ctx.fillStyle = `rgba(255,255,255,${0.2 + 0.8 * within})`;
    ctx.shadowColor = "#ff8fb0";
    ctx.shadowBlur = 30;
    ctx.fillText(count === 4 ? "준비" : String(count), width / 2, top + barHeight / 2 + 40);
    ctx.restore();
  }

  // 실시간 점수 (끝난 음표만)
  const finished = tallies.filter((_, index) => (melody[index].beat + melody[index].beats) * BEAT_SECONDS < heard);
  if (finished.length > 0) {
    const live = scoreSong(finished);
    const label = `🎤 ${live.score}  ·  음표 ${live.notesHit}/${live.notesTotal}`;
    ctx.font = `16px ${fonts.cute}`;
    const w = ctx.measureText(label).width + 28;
    ctx.fillStyle = "rgba(0,0,0,0.45)";
    rounded(ctx, width - w - 12, top + barHeight - 44, w, 34, 17);
    ctx.fillStyle = "#ffcc5c";
    ctx.fillText(label, width - w + 2, top + barHeight - 21);
  }
}

function rounded(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  if (w <= 0 || h <= 0) return;
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, Math.min(r, w / 2, h / 2));
  ctx.fill();
}
