// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 앱의 채점 연출(CelebrationView.swift)을 캔버스로 옮긴 불꽃·폭죽 엔진.
// 모든 그림은 "경과 초"의 순수 함수 — 같은 시드면 같은 장면.

export const COLORS = {
  gold: "#ffcc5c",
  pink: "#ff8fb0",
  mint: "#5ee0b8",
  sky: "#5cc7ff",
  orange: "#ff734d",
  violet: "#b88cff",
  white: "#ffffff",
} as const;

const PALETTE = [COLORS.gold, COLORS.pink, COLORS.mint, COLORS.sky, COLORS.orange, COLORS.violet];

type Kind = "peony" | "willow" | "crackle" | "ring" | "double";

type Particle = { angle: number; speed: number; phase: number; inner: boolean };

export type Burst = {
  time: number;
  /** 화면 비율 0…1 */
  x: number;
  y: number;
  launchX: number;
  kind: Kind;
  color: string;
  second: string;
  /** 화면 짧은 변 대비 세기 */
  power: number;
  particles: Particle[];
  headline: boolean;
};

export type Show = { bursts: Burst[]; crashTime: number };

/** 결정적 난수 (mulberry32) */
export function seeded(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const LAUNCH_LEAD = 0.55;

/** 점수만큼 불꽃 일정 (착지 순간 세 발 + 이어지는 불꽃 + 90점 이상 피날레) */
export function makeShow(score: number, seed: number, crashTime: number, scale = 1): Show {
  const random = seeded(seed);
  const between = (a: number, b: number) => a + (b - a) * random();
  const pick = <T,>(items: readonly T[]) => items[Math.min(items.length - 1, Math.floor(random() * items.length))];
  const bursts: Burst[] = [];

  const make = (time: number, x: number, y: number, kind: Kind, power: number, headline = false): Burst => {
    const color = kind === "willow" ? COLORS.gold : pick(PALETTE);
    const second = pick(PALETTE);
    const count = Math.round(({ peony: 130, willow: 90, crackle: 100, ring: 60, double: 160 } as const)[kind] * scale);
    const particles: Particle[] = Array.from({ length: count }, (_, index) => {
      const inner = kind === "double" && index % 2 === 0;
      return {
        angle: kind === "ring" ? (index / count) * Math.PI * 2 : between(0, Math.PI * 2),
        speed: kind === "ring" ? 1 : between(0.62, 1) * (inner ? 0.55 : 1),
        phase: between(0, Math.PI * 2),
        inner,
      };
    });
    return { time, x, y, launchX: x + between(-0.08, 0.08), kind, color, second, power, particles, headline };
  };

  bursts.push(make(crashTime, 0.5, 0.36, "double", 0.52, true));
  bursts.push(make(crashTime + 0.06, 0.16, 0.3, "peony", 0.36));
  bursts.push(make(crashTime + 0.12, 0.84, 0.27, "peony", 0.36));

  const extra = score >= 90 ? 9 : score >= 70 ? 6 : score >= 50 ? 3 : 1;
  let time = crashTime + 0.55;
  const kinds: Kind[] = ["peony", "willow", "crackle", "ring", "double"];
  for (let index = 0; index < extra; index++) {
    const left = index % 2 === 0;
    bursts.push(make(time, left ? between(0.08, 0.42) : between(0.58, 0.92), between(0.12, 0.45), pick(kinds), between(0.28, 0.42)));
    time += between(0.26, 0.42);
  }
  if (score >= 90) {
    time += 0.25;
    for (const x of [0.2, 0.5, 0.8]) bursts.push(make(time + between(0, 0.1), x, between(0.14, 0.3), "willow", 0.44));
  }
  return { bursts, crashTime };
}

/** 번쩍 (0…1) */
export function flashAmount(show: Show, t: number): number {
  let amount = 0;
  for (const burst of show.bursts) {
    const dt = t - burst.time;
    if (dt < 0 || dt >= 0.22) continue;
    amount = Math.max(amount, (burst.headline ? 0.32 : 0.1) * Math.pow(1 - dt / 0.22, 2));
  }
  return amount;
}

/** 화면 흔들림 (px) */
export function shake(show: Show, t: number): { x: number; y: number } {
  let x = 0;
  let y = 0;
  show.bursts.forEach((burst, index) => {
    const dt = t - burst.time;
    if (dt < 0 || dt >= 0.5) return;
    const amplitude = (burst.headline ? 14 : 5) * Math.exp(-dt * 9);
    x += amplitude * Math.sin(dt * 95 + index);
    y += amplitude * 0.7 * Math.cos(dt * 83 + index * 1.7);
  });
  return { x, y };
}

const rgba = (hex: string, alpha: number) => {
  const value = parseInt(hex.slice(1), 16);
  return `rgba(${(value >> 16) & 255},${(value >> 8) & 255},${value & 255},${Math.max(0, Math.min(1, alpha)).toFixed(3)})`;
};

export function drawFireworks(ctx: CanvasRenderingContext2D, show: Show, t: number, width: number, height: number) {
  const unit = Math.min(width, height);
  ctx.save();
  ctx.globalCompositeOperation = "lighter";
  ctx.lineCap = "round";
  for (const burst of show.bursts) {
    drawRocket(ctx, burst, t, width, height);
    drawBurst(ctx, burst, t, width, height, unit);
  }
  ctx.restore();
}

function drawRocket(ctx: CanvasRenderingContext2D, burst: Burst, t: number, width: number, height: number) {
  const local = t - (burst.time - LAUNCH_LEAD);
  if (local <= 0 || local >= LAUNCH_LEAD) return;
  const sx = burst.launchX * width;
  const sy = height * 1.02;
  const ex = burst.x * width;
  const ey = burst.y * height;
  const point = (u: number) => {
    const e = 1 - Math.pow(1 - Math.max(0, Math.min(1, u)), 2);
    return [sx + (ex - sx) * e, sy + (ey - sy) * e] as const;
  };
  const u = local / LAUNCH_LEAD;
  const [tx, ty] = point(Math.max(0, u - 0.28));
  const [hx, hy] = point(u);
  const gradient = ctx.createLinearGradient(tx, ty, hx, hy);
  gradient.addColorStop(0, rgba(burst.color, 0));
  gradient.addColorStop(1, "rgba(255,255,255,0.9)");
  ctx.strokeStyle = gradient;
  ctx.lineWidth = 3;
  ctx.beginPath();
  ctx.moveTo(tx, ty);
  ctx.lineTo(hx, hy);
  ctx.stroke();
  ctx.fillStyle = rgba(burst.color, 0.35);
  ctx.beginPath();
  ctx.arc(hx, hy, 9, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#fff";
  ctx.beginPath();
  ctx.arc(hx, hy, 3, 0, Math.PI * 2);
  ctx.fill();
}

function drawBurst(ctx: CanvasRenderingContext2D, burst: Burst, t: number, width: number, height: number, unit: number) {
  const local = t - burst.time;
  const willow = burst.kind === "willow";
  const life = willow ? 2.8 : 1.9;
  if (local <= 0 || local >= life) return;
  const cx = burst.x * width;
  const cy = burst.y * height;
  const power = burst.power * unit * 2.3;
  const drag = willow ? 1.3 : 2.5;
  const gravity = ((willow ? 150 : 80) * unit) / 760;
  const fade = Math.pow(1 - local / life, willow ? 0.9 : 1.4);

  // 팡: 빛 덩어리
  if (local < 0.3) {
    const k = 1 - local / 0.3;
    const radius = (((burst.headline ? 230 : 130) * (0.5 + 0.5 * (1 - k))) * unit) / 760;
    const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius);
    glow.addColorStop(0, `rgba(255,255,255,${0.95 * k})`);
    glow.addColorStop(0.45, rgba(burst.color, 0.55 * k));
    glow.addColorStop(1, rgba(burst.color, 0));
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fill();
  }
  // 팡!: 사방으로 뻗는 빛줄기
  if (local < 0.12) {
    const k = local / 0.12;
    const count = burst.headline ? 16 : 10;
    ctx.strokeStyle = `rgba(255,255,255,${0.9 * (1 - k)})`;
    ctx.lineWidth = burst.headline ? 4 : 2.5;
    ctx.beginPath();
    for (let index = 0; index < count; index++) {
      const angle = (index / count) * Math.PI * 2 + burst.particles[0].phase;
      const long = index % 2 === 0 ? 1 : 0.6;
      const inner = power * 0.05;
      const outer = power * (0.12 + 0.3 * k) * long;
      ctx.moveTo(cx + Math.cos(angle) * inner, cy + Math.sin(angle) * inner);
      ctx.lineTo(cx + Math.cos(angle) * outer, cy + Math.sin(angle) * outer);
    }
    ctx.stroke();
  }
  if (burst.headline && local < 0.3) {
    const k = local / 0.3;
    const radius = power * 0.32 * (1 - Math.pow(1 - k, 3));
    ctx.strokeStyle = rgba(burst.color, 0.35 * (1 - k));
    ctx.lineWidth = 10 * (1 - k) + 1;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.stroke();
  }

  const position = (particle: Particle, time: number) => {
    const at = Math.max(0, time);
    const travel = (particle.speed * power * (1 - Math.exp(-drag * at))) / drag;
    let dx = Math.cos(particle.angle) * travel;
    let dy = Math.sin(particle.angle) * travel;
    if (burst.kind === "ring") dy *= 0.42;
    dy += gravity * at * at;
    if (willow) dx += Math.sin(at * 2 + particle.phase) * 4;
    return [cx + dx, cy + dy] as const;
  };

  const hot = Math.max(0, 1 - local / 0.12);
  const segments = willow ? 14 : burst.kind === "ring" ? 3 : 9;
  const step = willow ? 0.05 : 0.03;
  for (const layer of burst.kind === "double" ? [false, true] : [false]) {
    const color = layer ? burst.second : burst.color;
    const particles = burst.particles.filter((particle) => particle.inner === layer);
    for (let segment = 0; segment < segments; segment++) {
      const a = local - segment * step;
      if (a <= 0) break;
      ctx.strokeStyle = rgba(color, fade * (1 - segment / segments) * (willow ? 0.75 : 0.9));
      ctx.lineWidth = (willow ? 3 : 3.6) * (1 - segment / (segments + 2));
      ctx.beginPath();
      for (const particle of particles) {
        const [x1, y1] = position(particle, a);
        const [x2, y2] = position(particle, a - step);
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
      }
      ctx.stroke();
    }
    const glowStyle = rgba(color, 0.32 * fade);
    const coreStyle = `rgba(255,255,255,${Math.min(1, fade * 0.7 + hot * 0.3).toFixed(3)})`;
    ctx.fillStyle = glowStyle;
    ctx.beginPath();
    const heads: [number, number][] = [];
    for (const particle of particles) {
      if (local > life * 0.55 && Math.sin(local * 38 + particle.phase * 5) < -0.2) continue;
      const [x, y] = position(particle, local);
      heads.push([x, y]);
      ctx.moveTo(x + 7, y);
      ctx.arc(x, y, 7, 0, Math.PI * 2);
    }
    ctx.fill();
    ctx.fillStyle = coreStyle;
    ctx.beginPath();
    for (const [x, y] of heads) {
      ctx.moveTo(x + 2.2, y);
      ctx.arc(x, y, 2.2, 0, Math.PI * 2);
    }
    ctx.fill();

    if (burst.kind === "crackle" && local > 0.7 && local < 1.4) {
      const bucket = Math.floor(local * 30);
      ctx.fillStyle = `rgba(255,255,255,${(0.9 * (1 - (local - 0.7) / 0.7)).toFixed(3)})`;
      ctx.beginPath();
      particles.forEach((particle, index) => {
        if ((index + bucket) % 3 !== 0) return;
        const [x, y] = position(particle, local);
        for (let k = 0; k < 3; k++) {
          const jx = ((index * 31 + bucket * 17 + k * 7) % 21) - 10;
          const jy = ((index * 13 + bucket * 29 + k * 11) % 21) - 10;
          ctx.moveTo(x + jx + 1.2, y + jy);
          ctx.arc(x + jx, y + jy, 1.2, 0, Math.PI * 2);
        }
      });
      ctx.fill();
    }
  }
}

type Piece = { sx: number; sy: number; vx: number; vy: number; spin: number; phase: number; color: string; w: number; h: number; delay: number; cannon: boolean };

const confettiCache = new Map<number, Piece[]>();

function confettiPieces(seed: number): Piece[] {
  const cached = confettiCache.get(seed);
  if (cached) return cached;
  const random = seeded(seed);
  const between = (a: number, b: number) => a + (b - a) * random();
  const colors = [COLORS.gold, COLORS.pink, COLORS.mint, COLORS.sky, COLORS.white, COLORS.orange];
  const pieces: Piece[] = [];
  for (const side of [0, 1]) {
    for (let index = 0; index < 110; index++) {
      const angle = (between(38, 78) * Math.PI) / 180;
      const speed = between(0.9, 2.1);
      const direction = side === 0 ? 1 : -1;
      pieces.push({
        sx: side === 0 ? 0.02 : 0.98, sy: 1.02,
        vx: Math.cos(angle) * speed * direction * 1.1, vy: -Math.sin(angle) * speed,
        spin: between(6, 16), phase: between(0, Math.PI * 2),
        color: colors[Math.floor(random() * colors.length)],
        w: between(6, 10), h: between(10, 16), delay: between(0, 0.12), cannon: true,
      });
    }
  }
  for (let index = 0; index < 70; index++) {
    pieces.push({
      sx: between(0, 1), sy: between(-0.35, -0.05), vx: 0, vy: between(0.1, 0.2),
      spin: between(3, 9), phase: between(0, Math.PI * 2),
      color: colors[Math.floor(random() * colors.length)],
      w: between(6, 9), h: between(9, 14), delay: between(0.2, 1.2), cannon: false,
    });
  }
  confettiCache.set(seed, pieces);
  return pieces;
}

/** 폭죽: 양쪽 아래 대포 + 위에서 내리는 종이. since = 착지부터 지난 초 */
export function drawConfetti(ctx: CanvasRenderingContext2D, since: number, width: number, height: number, seed = 99) {
  if (since <= 0) return;
  for (const piece of confettiPieces(seed)) {
    const t = since - piece.delay;
    if (t <= 0) continue;
    let x: number;
    let y: number;
    if (piece.cannon) {
      const drag = 2.6;
      const rise = (1 - Math.exp(-drag * t)) / drag;
      x = piece.sx * width + piece.vx * height * rise;
      y = piece.sy * height + piece.vy * height * rise + 0.09 * height * t * t;
    } else {
      x = piece.sx * width;
      y = piece.sy * height + piece.vy * height * t;
    }
    x += Math.sin(t * 3 + piece.phase) * 18 * Math.min(1, t);
    if (y > height + 30) continue;
    const flip = Math.cos(t * piece.spin + piece.phase);
    const alpha = Math.min(1, (6 - t) / 1.5) * (flip > 0 ? 1 : 0.7);
    if (alpha <= 0) continue;
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(t * piece.spin * 0.4 + piece.phase);
    ctx.globalAlpha = alpha;
    ctx.fillStyle = piece.color;
    const w = piece.w * Math.max(0.15, Math.abs(flip));
    ctx.fillRect(-w / 2, -piece.h / 2, w, piece.h);
    ctx.restore();
  }
}
