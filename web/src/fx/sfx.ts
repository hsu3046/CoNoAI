// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 채점 연출 효과음 (Web Audio): 드럼롤(Freesound 569113, CC0) + 불꽃 팡·로켓(CoNo 합성).
// 소리를 장면 시각에 맞춰 예약한다 — 화면과 같은 기준 시각(AudioContext.currentTime)을 쓴다.

import { LAUNCH_LEAD, type Show } from "./fireworks";

const FILES = {
  drumroll: "/sfx/drumroll.m4a",
  bang1: "/sfx/bang1.m4a",
  bang2: "/sfx/bang2.m4a",
  bang3: "/sfx/bang3.m4a",
  launch: "/sfx/launch.m4a",
} as const;

type Name = keyof typeof FILES;

const cache = new WeakMap<AudioContext, Promise<Partial<Record<Name, AudioBuffer>>>>();

/** 효과음을 한 번만 받아 디코드한다. 실패한 소리는 빠진 채로 (연출은 소리 없이도 돈다) */
export function loadSfx(ctx: AudioContext) {
  let pending = cache.get(ctx);
  if (!pending) {
    pending = (async () => {
      const entries = await Promise.all(
        (Object.keys(FILES) as Name[]).map(async (name) => {
          try {
            const response = await fetch(FILES[name]);
            const buffer = await ctx.decodeAudioData(await response.arrayBuffer());
            return [name, buffer] as const;
          } catch {
            return [name, undefined] as const;
          }
        }),
      );
      return Object.fromEntries(entries.filter(([, buffer]) => buffer)) as Partial<Record<Name, AudioBuffer>>;
    })();
    cache.set(ctx, pending);
  }
  return pending;
}

/** 드럼롤·로켓·팡을 예약하고, 멈추는 함수를 돌려준다. start = 장면 0초의 ctx 시각 */
export async function playCelebration(ctx: AudioContext, show: Show, start: number, volume = 0.9) {
  const buffers = await loadSfx(ctx);
  const nodes: AudioBufferSourceNode[] = [];
  const master = ctx.createGain();
  master.gain.value = volume;
  master.connect(ctx.destination);

  const play = (name: Name, at: number, gain: number, pan = 0) => {
    const buffer = buffers[name];
    if (!buffer || at < ctx.currentTime - 0.05) return;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    const level = ctx.createGain();
    level.gain.value = gain;
    const panner = ctx.createStereoPanner();
    panner.pan.value = pan;
    source.connect(level).connect(panner).connect(master);
    source.start(Math.max(ctx.currentTime, at));
    nodes.push(source);
  };

  play("drumroll", start, 0.8);
  let lastLaunch = -10;
  for (const burst of show.bursts) {
    const at = burst.time - LAUNCH_LEAD;
    if (at - lastLaunch > 0.25) {
      play("launch", start + at, 0.35, (burst.x * 2 - 1) * 0.6);
      lastLaunch = at;
    }
  }
  show.bursts.forEach((burst, index) => {
    const name = (["bang1", "bang2", "bang3"] as const)[index % 3];
    play(name, start + burst.time, burst.headline ? 0.95 : 0.55 + 0.1 * (index % 3), (burst.x * 2 - 1) * 0.7);
  });

  return () => {
    for (const node of nodes) {
      try {
        node.stop();
      } catch {
        // 이미 끝난 소리
      }
    }
    master.disconnect();
  };
}
