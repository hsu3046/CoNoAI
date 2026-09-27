// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 스크롤 스토리: 화면이 고정된 채 스크롤만큼 장면이 바뀐다.
//   ① 음악 파형 → ② 분홍 보컬이 빨려 나가고 민트 반주만 → ③ 가사·음정 바 → ④ 금색 내 목소리 · 점수 · 불꽃

"use client";

import { useEffect, useRef, useState } from "react";
import { drawConfetti, drawFireworks, makeShow } from "@/fx/fireworks";
import { canvasFonts } from "@/fx/hooks";

const SCENES = [
  {
    step: "01",
    title: "음악 앱에서, 아무 노래나 ▶",
    body: "Apple Music · YouTube · Spotify · 멜론… 소리만 나면 뭐든 OK! CoNo가 반주만 남기고, 가사 표시와 채점까지 진행합니다.",
    chips: ["Apple Music", "YouTube", "Spotify", "멜론", "그 외 다양한 음악앱"],
  },
  {
    step: "02",
    title: "AI가 목소리만 쏙 분리",
    body: "내 컴퓨터 안에서 AI가 보컬을 제거하고 반주만 남깁니다.\n가이드가 필요할 땐, 가수 목소리를 살짝 섞어보세요.",
    chips: ["내 컴퓨터 안에서", "실시간", "가이드 보컬"],
  },
  {
    step: "03",
    title: "원곡 음정과 가사가 화면에",
    body: "AI가 원곡 가수의 음정을 자동으로 읽어 음정 바로 보여 줘요. 가사도 알아서 찾아와 노래에 맞춰 글자마다 색칠됩니다. 노래방 기계처럼 키를 올리고 내려 내 목소리에 딱 맞게.",
    chips: ["원곡 음정 자동 인식", "키 조절", "글자마다 색칠되는 가사"],
  },
  {
    step: "04",
    title: "부르면 채점, 끝나면 팡팡",
    body: "마이크로 부르면 내 음정이 금색 선으로 겹쳐져요. 곡이 끝나면 드럼롤과 불꽃놀이. 스피커로 틀어도 반주는 걸러냅니다.",
    chips: ["옥타브 무관", "실시간 채점", "불꽃놀이"],
  },
] as const;

// 음정 바에 흐를 가짜 음표 (반음, 시작 초, 길이 초) — 한 바퀴 8초
const NOTES = [
  [0, 0.0, 0.5], [4, 0.55, 0.5], [7, 1.1, 0.5], [4, 1.65, 0.45], [5, 2.2, 0.8], [4, 3.05, 0.3], [2, 3.4, 0.9],
  [2, 4.4, 0.5], [5, 4.95, 0.5], [9, 5.5, 0.5], [5, 6.05, 0.45], [7, 6.6, 0.8], [4, 7.45, 0.5],
] as const;
const LOOP = 8;
const LYRIC = "오늘 밤은 우리 집 무대 위로 올라가";

export function StoryScroll() {
  const sectionRef = useRef<HTMLElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  // 스크롤 진행도는 ref 로만 (매 스크롤마다 다시 렌더하지 않는다). 글은 장면이 바뀔 때만 바뀐다
  const progressRef = useRef(0);
  const [scene, setScene] = useState(0);
  // ② 가이드 보컬 슬라이더 (0 = 반주만, 1 = 원곡처럼). 그리기 루프는 ref 로 읽는다
  const [guide, setGuide] = useState(0);
  const guideRef = useRef(0);
  // 슬라이더 폭 = ② 설명 문단에서 가장 긴 줄의 실제 폭 (낱말 단위 줄바꿈이라 글줄이 칸보다 짧다)
  const guideTextRef = useRef<HTMLParagraphElement>(null);
  const [guideWidth, setGuideWidth] = useState<number | null>(null);
  useEffect(() => {
    const paragraph = guideTextRef.current;
    if (!paragraph) return;
    const measure = () => {
      const range = document.createRange();
      range.selectNodeContents(paragraph);
      const left = paragraph.getBoundingClientRect().left;
      const right = Math.max(...[...range.getClientRects()].map((rect) => rect.right));
      if (Number.isFinite(right)) setGuideWidth(Math.ceil(right - left));
    };
    const observer = new ResizeObserver(measure);
    observer.observe(paragraph);
    void document.fonts.ready.then(measure);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const section = sectionRef.current;
    const canvas = canvasRef.current;
    const stageElement = stageRef.current;
    const ctx = canvas?.getContext("2d");
    if (!section || !canvas || !stageElement || !ctx) return;

    // 크기·무대 위치는 바뀔 때만 잰다 (매 프레임 재면 스크롤 중 레이아웃 계산이 끼어든다)
    // 화면 전체 캔버스라 해상도는 1.5배까지만
    const ratio = Math.min(1.5, window.devicePixelRatio || 1);
    let width = 0;
    let height = 0;
    let stage = { x: 0, y: 0, w: 0, h: 0 };
    const measure = () => {
      width = canvas.clientWidth;
      height = canvas.clientHeight;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      const box = canvas.getBoundingClientRect();
      const area = stageElement.getBoundingClientRect();
      stage = { x: area.left - box.left, y: area.top - box.top, w: area.width, h: area.height };
    };
    measure();
    const resize = new ResizeObserver(measure);
    resize.observe(canvas);
    resize.observe(stageElement);

    const updateProgress = () => {
      const rect = section.getBoundingClientRect();
      const travel = rect.height - window.innerHeight;
      progressRef.current = travel > 0 ? clamp(-rect.top / travel) : 0;
      const next = Math.min(3, Math.floor(sceneProgress(progressRef.current) * 0.9999));
      setScene((current) => (current === next ? current : next));
    };
    updateProgress();
    window.addEventListener("scroll", updateProgress, { passive: true });

    const start = performance.now();
    const show = makeShow(92, 7, 0, 0.55);
    let secondEnteredAt: number | null = null;
    let fourthEnteredAt: number | null = null;
    let frame = 0;
    let visible = false;
    let shownGuide = 0; // 슬라이더를 부드럽게 따라가는 값

    const draw = (now: number) => {
      // 화면 밖이면 멈춘다 (불꽃 장면이 페이지 끝까지 따라오며 그리던 문제)
      if (!visible) {
        frame = 0;
        return;
      }
      frame = requestAnimationFrame(draw);
      if (width === 0) return;
      const t = (now - start) / 1000;
      const p = sceneProgress(progressRef.current);
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, width, height);

      // 장면 섞임 정도
      // ② 에서 보컬 떼어내기는 중반까지 끝내고, 파형은 ② 끝무렵에만 사라진다 — 그 사이 가이드 보컬 슬라이더를 만져 볼 수 있게
      const wave = clamp((2.05 - p) / 0.25); // ①② 파형 (③ 직전에 사라짐)
      // ② 보컬 떼어내기: 들어선 순간부터 시간으로 1.5초 (스크롤에 묶으면 휠 몇 칸에 끝나 안 보인다). ① 로 돌아가면 처음부터
      if (p >= 1 && secondEnteredAt === null) secondEnteredAt = t;
      if (p < 0.95) secondEnteredAt = null;
      const peel = secondEnteredAt === null ? 0 : clamp((t - secondEnteredAt) / 1.5);
      const bar = clamp(p - 1.9); // ③④ 음정 바
      const sing = clamp((p - 2.55) / 0.35); // ③ 끝무렵부터 내 목소리
      // ④ 에 들어서는 순간 점수가 92에 닿으며 바로 불꽃 (시간이 아니라 스크롤에 맞춘다 — 기다려야 터지면 지나쳐 버린다)
      if (p >= 3 && fourthEnteredAt === null) fourthEnteredAt = t;
      if (p < 2.95) fourthEnteredAt = null;

      // 파형·음정 바는 무대 영역에, 불꽃은 화면 전체에
      ctx.save();
      ctx.translate(stage.x, stage.y);
      shownGuide += (guideRef.current - shownGuide) * 0.15;
      if (wave > 0) drawWave(ctx, stage.w, stage.h, t, peel, wave, shownGuide);
      if (bar > 0) drawPitchBar(ctx, stage.w, stage.h, t, bar, sing);
      ctx.restore();
      if (fourthEnteredAt !== null) {
        const local = (t - fourthEnteredAt) % 7;
        drawFireworks(ctx, show, local, width, height);
        drawConfetti(ctx, local, width, height, 5);
      }
      // 점수: ④ 에 들어선 순간부터 시간으로 2.4초 동안 올라간다 (스크롤에 묶으면 한 번 넘길 때 순식간에 끝나 안 보인다)
      const count = fourthEnteredAt === null ? 0 : clamp((t - fourthEnteredAt) / 2.4);
      if (count > 0) {
        // 점수는 무대가 아니라 화면 한가운데에 크게
        drawScore(ctx, width, height, Math.floor(92 * easeOut(count)), Math.min(1, count * 3));
      }
    };

    const observer = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (visible && !frame) frame = requestAnimationFrame(draw);
    });
    observer.observe(section);

    return () => {
      observer.disconnect();
      resize.disconnect();
      window.removeEventListener("scroll", updateProgress);
      cancelAnimationFrame(frame);
    };
  }, []);

  return (
    <section id="story" ref={sectionRef} className="relative h-[440vh] snap-start">
      <div className="sticky top-0 flex h-dvh flex-col overflow-hidden lg:flex-row">
        <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_70%_50%,#1f1238,transparent_70%)]" />
        <canvas ref={canvasRef} className="pointer-events-none absolute inset-0 size-full" aria-label="CoNo가 노래를 노래방으로 바꾸는 과정 애니메이션" role="img" />
        {/* 설명 */}
        <div className="relative z-10 flex shrink-0 flex-col justify-end px-6 pb-4 pt-24 lg:w-[42%] lg:justify-center lg:py-0 lg:pl-[calc(max(0px,(100vw-1280px)/2)+48px)]">
          {/* 장면 표시 — 누르면 그 장면으로 (장면 구간의 60% 지점: ② 보컬 떼어내기가 끝난 뒤, ④ 불꽃이 터진 뒤) */}
          <div className="mb-4 flex gap-1" role="tablist" aria-label="장면">
            {SCENES.map((item, index) => (
              <button
                key={item.step}
                type="button"
                role="tab"
                aria-selected={index === scene}
                aria-label={`${item.step} ${item.title}`}
                onClick={() => {
                  const section = sectionRef.current;
                  if (!section) return;
                  const progress = SCENE_BOUNDS[index] + (SCENE_BOUNDS[index + 1] - SCENE_BOUNDS[index]) * 0.6;
                  window.scrollTo({ top: section.offsetTop + (section.offsetHeight - window.innerHeight) * progress, behavior: "smooth" });
                }}
                className="group py-2.5"
              >
                <span
                  className={`block h-1.5 rounded-full transition-all duration-500 ${index === scene ? "w-10 bg-pink" : "w-4 bg-white/15 group-hover:w-6 group-hover:bg-white/40"}`}
                />
              </button>
            ))}
          </div>
          <div className="relative min-h-[300px] sm:min-h-[280px]">
            {SCENES.map((item, index) => (
              <article
                key={item.step}
                className={`absolute inset-0 transition-all duration-500 ${index === scene ? "translate-y-0 opacity-100" : index < scene ? "pointer-events-none -translate-y-6 opacity-0" : "pointer-events-none translate-y-6 opacity-0"}`}
                aria-hidden={index !== scene}
              >
                <p className="font-display text-5xl text-pink/80 sm:text-6xl">{item.step}</p>
                <h2 className="mt-1 font-cute text-3xl sm:text-4xl">{item.title}</h2>
                <p ref={index === 1 ? guideTextRef : undefined} className="mt-3 max-w-md whitespace-pre-line text-base leading-relaxed text-ink2">
                  {item.body}
                </p>
                <div className="mt-4 flex flex-wrap gap-2">
                  {item.chips.map((chip) => (
                    <span key={chip} className="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-sm text-ink2">
                      {chip}
                    </span>
                  ))}
                </div>
                {index === 1 && (
                  <GuideSlider
                    width={guideWidth}
                    value={guide}
                    onChange={(value) => {
                      guideRef.current = value;
                      setGuide(value);
                    }}
                  />
                )}
              </article>
            ))}
          </div>
        </div>
        {/* 장면이 그려지는 자리 (캔버스는 화면 전체 — 불꽃이 설명 쪽까지 퍼진다) */}
        <div ref={stageRef} className="relative min-h-0 flex-1" />
      </div>
    </section>
  );
}

/** 가이드 보컬 슬라이더: 올리면 떼어 낸 분홍 보컬이 파형으로 다시 자라난다 (앱의 가이드 보컬과 같은 뜻) */
function GuideSlider({ width, value, onChange }: { width: number | null; value: number; onChange: (value: number) => void }) {
  const percent = Math.round(value * 100);
  return (
    <label style={width ? { width } : undefined} className="mt-5 block max-w-md rounded-2xl border border-pink/25 bg-pink/[0.06] px-4 py-3">
      <span className="flex items-center justify-between font-cute text-base">
        <span>가이드 보컬</span>
        <span className="tabular-nums text-pink">{percent === 0 ? "0% · 반주만" : percent === 100 ? "100% · 원곡처럼" : `${percent}%`}</span>
      </span>
      <input
        type="range"
        min={0}
        max={100}
        value={percent}
        onChange={(event) => onChange(Number(event.target.value) / 100)}
        aria-label="가이드 보컬 크기"
        className="guide-range mt-2 w-full outline-none focus-visible:ring-2 focus-visible:ring-pink/60"
        style={{ background: `linear-gradient(to right, #ff8fb0 ${percent}%, rgba(255,255,255,0.12) ${percent}%)` }}
      />
    </label>
  );
}

const clamp = (value: number) => Math.min(1, Math.max(0, value));

/** 섹션 스크롤 진행도(0…1) → 장면 진행도(0…4). ④(불꽃)에 스크롤을 더 준다 — 지나치기 전에 충분히 보게 */
const SCENE_BOUNDS = [0, 0.2, 0.4, 0.6, 1];
function sceneProgress(progress: number): number {
  for (let index = 0; index < 4; index++) {
    const from = SCENE_BOUNDS[index];
    const to = SCENE_BOUNDS[index + 1];
    if (progress < to || index === 3) return index + clamp((progress - from) / (to - from));
  }
  return 4;
}
const easeOut = (x: number) => 1 - Math.pow(1 - x, 3);
const easeInOut = (x: number) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);

/** 파형: 막대 = 민트 반주 + 분홍 보컬. peel 만큼 보컬이 떨어져 위로 빨려 나간다 */
function drawWave(ctx: CanvasRenderingContext2D, width: number, height: number, t: number, peel: number, alpha: number, guide: number) {
  const count = Math.max(28, Math.min(72, Math.floor(width / 12)));
  const mid = height * 0.58;
  // AI 구슬은 파형 오른쪽 끝, 파형 가운데선에. 파형은 설명 문단 왼쪽(24px)부터 구슬 앞까지
  const left = 24;
  const cx = width - 24 - 60;
  const cy = mid;
  const gap = Math.max(0, cx - 28 - left) / count; // 막대가 구슬 빛 안까지 — 구슬에서 흘러나오는 것처럼
  ctx.save();
  ctx.globalAlpha = alpha;
  // AI 글자는 파형 뒤에, 빛 번짐은 파형 위에 (막대가 빛 속에서 흘러나오는 것처럼)
  const orbAlpha = alpha * clamp(peel * 3);
  // 빨아들이는 동안 구슬이 부풀며 숨쉰다
  const radius = 110 + 26 * Math.sin(Math.min(1, peel) * Math.PI) + 5 * Math.sin(t * 6);
  if (peel > 0) {
    ctx.globalAlpha = orbAlpha;
    ctx.fillStyle = "#fff";
    ctx.font = `34px ${canvasFonts().cute}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText("AI", cx, cy);
  }
  ctx.globalAlpha = alpha;
  for (let index = 0; index < count; index++) {
    const phase = index * 0.45 + t * 3.2;
    const accompaniment = (0.18 + 0.12 * Math.sin(phase) + 0.08 * Math.sin(phase * 2.3 + 1)) * height * 0.5;
    const vocal = (0.1 + 0.1 * Math.abs(Math.sin(index * 0.2 + t * 1.7))) * height * 0.5;
    const x = left + index * gap;
    const w = Math.max(3, gap * 0.55);
    // 반주
    ctx.fillStyle = "#5ee0b8";
    roundRect(ctx, x, mid - accompaniment, w, accompaniment * 2, w / 2);
    // 보컬: 떼어 내는 동안 볼륨을 내리듯 줄어든다
    const delay = (index / count) * 0.55;
    const local = clamp((peel - delay) / 0.45);
    const startY = mid - accompaniment - vocal * 2;
    if (local > 0 && guide > 0.01) {
      // 가이드 보컬: 떼어 내기 시작한 막대마다 슬라이더만큼 분홍 보컬이 반주 위로 다시 자란다
      const h = vocal * 2 * guide;
      ctx.globalAlpha = alpha * (0.55 + 0.45 * guide);
      ctx.fillStyle = "#ff8fb0";
      roundRect(ctx, x, mid - accompaniment - h, w, h, Math.min(w / 2, h / 2));
      ctx.globalAlpha = alpha;
    }
    if (local <= 0) {
      ctx.fillStyle = "#ff8fb0";
      roundRect(ctx, x, startY, w, vocal * 2, w / 2);
    } else if (local < 1) {
      // 볼륨을 내리듯 위에서 아래로 줄어든다 (아래쪽은 반주 위에 붙은 채). 줄어드는 끝은 밝게
      const h = vocal * 2 * (1 - easeInOut(local));
      ctx.fillStyle = "#ff8fb0";
      roundRect(ctx, x, mid - accompaniment - h, w, h, Math.min(w / 2, h / 2));
      ctx.fillStyle = "#ffd1df";
      ctx.globalAlpha = alpha * (1 - local);
      roundRect(ctx, x, mid - accompaniment - h - 1, w, Math.min(h, w), w / 2);
      ctx.globalAlpha = alpha;
    }
  }
  if (peel > 0) {
    ctx.globalAlpha = orbAlpha;
    const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
    // 넓게, 바깥으로 갈수록 서서히 옅어지게 (가운데 밝기는 그대로)
    glow.addColorStop(0, "rgba(255,209,223,0.75)");
    glow.addColorStop(0.18, "rgba(255,160,190,0.5)");
    glow.addColorStop(0.45, "rgba(255,143,176,0.2)");
    glow.addColorStop(0.75, "rgba(255,143,176,0.06)");
    glow.addColorStop(1, "rgba(255,143,176,0)");
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.restore();
}

/** 음정 바 + 가사 (+ sing 만큼 금색 내 목소리 선) */
function drawPitchBar(ctx: CanvasRenderingContext2D, width: number, height: number, t: number, alpha: number, sing: number) {
  const top = height * 0.12;
  const barHeight = height * 0.46;
  const left = width * 0.06;
  const right = width * 0.96;
  ctx.save();
  ctx.globalAlpha = alpha;
  // 판
  ctx.fillStyle = "rgba(0,0,0,0.3)";
  roundRect(ctx, left, top, right - left, barHeight, 18);
  // 반음 격자
  ctx.strokeStyle = "rgba(255,255,255,0.05)";
  ctx.lineWidth = 1;
  for (let row = 0; row <= 12; row++) {
    const y = top + (row / 12) * barHeight;
    ctx.beginPath();
    ctx.moveTo(left, y);
    ctx.lineTo(right, y);
    ctx.stroke();
  }
  const window = 5;
  const playheadX = left + (right - left) * 0.28;
  const now = t % LOOP;
  const xOf = (time: number) => playheadX + ((time - now) / window) * (right - left);
  const yOf = (semitone: number) => top + barHeight - ((semitone + 1.5) / 12) * barHeight;
  const rowHeight = barHeight / 12;

  const drawNotes = (offset: number) => {
    for (const [semitone, start, length] of NOTES) {
      const s = start + offset;
      const x1 = xOf(s);
      const x2 = xOf(s + length);
      if (x2 < left || x1 > right) continue;
      const current = s <= now && now < s + length;
      const passed = s + length < now;
      if (current) {
        ctx.fillStyle = sing > 0.3 ? "rgba(255,204,92,0.45)" : "rgba(94,224,184,0.25)";
        roundRect(ctx, x1 - 6, yOf(semitone) - rowHeight / 2 - 5, x2 - x1 + 12, rowHeight + 10, rowHeight / 2 + 5);
      }
      ctx.fillStyle = passed ? (sing > 0.3 ? "rgba(255,204,92,0.6)" : "rgba(255,255,255,0.16)") : current ? "#5ee0b8" : "rgba(255,255,255,0.8)";
      roundRect(ctx, Math.max(left, x1), yOf(semitone) - rowHeight / 2 + 2, Math.min(right, x2) - Math.max(left, x1), rowHeight - 4, rowHeight / 2);
    }
  };
  ctx.save();
  ctx.beginPath();
  ctx.rect(left, top, right - left, barHeight);
  ctx.clip();
  drawNotes(-LOOP);
  drawNotes(0);
  drawNotes(LOOP);

  // 금색 내 목소리: 음표를 살짝 흔들리며 따라간다
  if (sing > 0) {
    ctx.globalAlpha = alpha * sing;
    ctx.strokeStyle = "#ffcc5c";
    ctx.lineWidth = 4;
    ctx.lineCap = "round";
    ctx.shadowColor = "#ffcc5c";
    ctx.shadowBlur = 12;
    ctx.beginPath();
    let started = false;
    for (let dt = -1.2; dt <= 0; dt += 0.02) {
      const time = now + dt;
      const note = noteAt(time);
      if (note === null) {
        started = false;
        continue;
      }
      const wobble = Math.sin(time * 24) * 0.12 + Math.sin(time * 5) * 0.08;
      const x = xOf(time);
      const y = yOf(note + wobble);
      if (!started) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
      started = true;
    }
    ctx.stroke();
    ctx.shadowBlur = 0;
  }
  ctx.restore();

  // 재생선
  ctx.globalAlpha = alpha;
  ctx.strokeStyle = "rgba(255,143,176,0.9)";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(playheadX, top);
  ctx.lineTo(playheadX, top + barHeight);
  ctx.stroke();

  // 가사: 글자마다 색칠
  const lyricY = top + barHeight + Math.min(90, height * 0.14);
  const fontSize = Math.max(22, Math.min(44, width / 22));
  ctx.font = `${fontSize}px ${canvasFonts().cute}`;
  ctx.textAlign = "left";
  const textWidth = ctx.measureText(LYRIC).width;
  const x = (left + right) / 2 - textWidth / 2;
  const fill = (now / LOOP) * textWidth;
  ctx.fillStyle = "rgba(237,240,255,0.35)";
  ctx.fillText(LYRIC, x, lyricY);
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, lyricY - fontSize, fill, fontSize * 1.4);
  ctx.clip();
  const gradient = ctx.createLinearGradient(x, 0, x + textWidth, 0);
  gradient.addColorStop(0, "#5cc7ff");
  gradient.addColorStop(1, "#5ee0b8");
  ctx.fillStyle = gradient;
  ctx.fillText(LYRIC, x, lyricY);
  ctx.restore();
  ctx.restore();
}

function noteAt(time: number): number | null {
  const local = ((time % LOOP) + LOOP) % LOOP;
  for (const [semitone, start, length] of NOTES) {
    if (local >= start && local < start + length) return semitone;
  }
  return null;
}

/** 점수: 화면 정중앙, 크게. 뒤를 살짝 어둡게 눌러 음정 바·불꽃 위에서도 읽히게 */
function drawScore(ctx: CanvasRenderingContext2D, width: number, height: number, score: number, alpha: number) {
  ctx.save();
  ctx.globalAlpha = alpha;
  const x = width / 2;
  const y = height / 2;
  const size = Math.max(110, Math.min(240, Math.min(width, height) / 3.2));
  const shade = ctx.createRadialGradient(x, y, 0, x, y, size * 1.4);
  shade.addColorStop(0, "rgba(11,13,26,0.55)");
  shade.addColorStop(1, "rgba(11,13,26,0)");
  ctx.fillStyle = shade;
  ctx.fillRect(x - size * 1.4, y - size * 1.4, size * 2.8, size * 2.8);
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.font = `${size}px ${canvasFonts().display}`;
  ctx.shadowColor = "#ff9a33";
  ctx.shadowBlur = size * 0.3;
  const gradient = ctx.createLinearGradient(0, y - size / 2, 0, y + size / 2);
  gradient.addColorStop(0, "#fff7c7");
  gradient.addColorStop(1, "#ff8a38");
  ctx.fillStyle = gradient;
  ctx.fillText(String(score), x, y);
  const half = ctx.measureText(String(score)).width / 2;
  ctx.shadowBlur = 0;
  ctx.font = `${Math.round(size * 0.2)}px ${canvasFonts().cute}`;
  ctx.fillStyle = "#c9cfee";
  ctx.textAlign = "left";
  ctx.textBaseline = "alphabetic";
  ctx.fillText("점", x + half + size * 0.06, y + size * 0.36);
  ctx.restore();
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  if (w <= 0 || h <= 0) return;
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, Math.min(r, w / 2, h / 2));
  ctx.fill();
}
