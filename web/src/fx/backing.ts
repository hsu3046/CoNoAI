// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 체험곡 반주 (Web Audio 로 즉석 합성): 카운트 · 코드 패드 · 베이스 · 킥/스네어/하이햇 · 가이드 멜로디.
// 모든 소리를 시작할 때 한꺼번에 예약하고, 멈출 때 한꺼번에 끈다.

import { BEAT_SECONDS, COUNT_IN_BEATS, TOTAL_BEATS, chords, melody, midiToHz } from "@/lib/melody";

export type BackingOptions = { guide: boolean };

export type Backing = {
  /** 노래 0박의 ctx 시각 (카운트가 끝나는 순간) */
  songStart: number;
  stop: () => void;
};

export function playBacking(ctx: AudioContext, options: BackingOptions): Backing {
  const start = ctx.currentTime + 0.25;
  const songStart = start + COUNT_IN_BEATS * BEAT_SECONDS;
  const sources: AudioScheduledSourceNode[] = [];

  const master = ctx.createGain();
  master.gain.value = 0.55;
  const compressor = ctx.createDynamicsCompressor();
  compressor.threshold.value = -16;
  compressor.ratio.value = 4;
  master.connect(compressor).connect(ctx.destination);

  const noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
  const data = noise.getChannelData(0);
  for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;

  const envelope = (gain: GainNode, at: number, peak: number, attack: number, decay: number, hold = 0) => {
    gain.gain.setValueAtTime(0.0001, at);
    gain.gain.exponentialRampToValueAtTime(peak, at + attack);
    if (hold > 0) gain.gain.setValueAtTime(peak, at + attack + hold);
    gain.gain.exponentialRampToValueAtTime(0.0001, at + attack + hold + decay);
  };

  const tone = (type: OscillatorType, hz: number, at: number, peak: number, attack: number, decay: number, hold = 0, filterHz?: number) => {
    const oscillator = ctx.createOscillator();
    oscillator.type = type;
    oscillator.frequency.value = hz;
    const gain = ctx.createGain();
    envelope(gain, at, peak, attack, decay, hold);
    if (filterHz) {
      const filter = ctx.createBiquadFilter();
      filter.type = "lowpass";
      filter.frequency.value = filterHz;
      oscillator.connect(filter).connect(gain).connect(master);
    } else {
      oscillator.connect(gain).connect(master);
    }
    oscillator.start(at);
    oscillator.stop(at + attack + hold + decay + 0.05);
    sources.push(oscillator);
  };

  const hit = (at: number, peak: number, type: BiquadFilterType, hz: number, decay: number) => {
    const source = ctx.createBufferSource();
    source.buffer = noise;
    const filter = ctx.createBiquadFilter();
    filter.type = type;
    filter.frequency.value = hz;
    const gain = ctx.createGain();
    envelope(gain, at, peak, 0.002, decay);
    source.connect(filter).connect(gain).connect(master);
    source.start(at);
    source.stop(at + decay + 0.05);
    sources.push(source);
  };

  const kick = (at: number) => {
    const oscillator = ctx.createOscillator();
    oscillator.frequency.setValueAtTime(130, at);
    oscillator.frequency.exponentialRampToValueAtTime(42, at + 0.14);
    const gain = ctx.createGain();
    envelope(gain, at, 0.9, 0.003, 0.28);
    oscillator.connect(gain).connect(master);
    oscillator.start(at);
    oscillator.stop(at + 0.35);
    sources.push(oscillator);
  };

  // 카운트: 똑 똑 똑 똑
  for (let beat = 0; beat < COUNT_IN_BEATS; beat++) {
    tone("sine", beat === 0 ? 1320 : 990, start + beat * BEAT_SECONDS, 0.35, 0.002, 0.08);
  }

  const beatTime = (beat: number) => songStart + beat * BEAT_SECONDS;
  chords.forEach((chord, bar) => {
    const at = beatTime(bar * 4);
    const length = 4 * BEAT_SECONDS;
    // 패드: 삼각파 + 한 옥타브 아래 사인
    for (const note of chord.tones) {
      tone("triangle", midiToHz(note), at, 0.05, 0.08, 0.5, length - 0.55, 1800);
      tone("sine", midiToHz(note - 12), at, 0.04, 0.1, 0.5, length - 0.6);
    }
    for (let beat = 0; beat < 4; beat++) {
      const t = beatTime(bar * 4 + beat);
      // 베이스: 1·3박 근음, 2·4박 5도
      tone("triangle", midiToHz(chord.root - 12 + (beat % 2 === 1 ? 7 : 0)), t, 0.35, 0.01, 0.35, 0, 600);
      if (beat % 2 === 0) kick(t);
      else hit(t, 0.35, "bandpass", 1900, 0.16);
      hit(t, 0.08, "highpass", 7500, 0.04);
      hit(t + BEAT_SECONDS / 2, 0.06, "highpass", 8000, 0.03);
    }
  });
  // 끝: 심벌 한 번
  hit(beatTime(TOTAL_BEATS - 4), 0.18, "highpass", 5000, 1.6);

  if (options.guide) {
    for (const note of melody) {
      const at = beatTime(note.beat);
      const length = note.beats * BEAT_SECONDS * 0.9;
      tone("triangle", midiToHz(note.midi), at, 0.12, 0.02, 0.12, Math.max(0, length - 0.14), 2600);
    }
  }

  return {
    songStart,
    stop: () => {
      const now = ctx.currentTime;
      master.gain.cancelScheduledValues(now);
      master.gain.setTargetAtTime(0, now, 0.05);
      for (const source of sources) {
        try {
          source.stop(now + 0.2);
        } catch {
          // 이미 끝난 소리
        }
      }
      window.setTimeout(() => master.disconnect(), 400);
    },
  };
}
