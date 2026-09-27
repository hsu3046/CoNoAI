// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 원곡·반주·보컬 세 트랙을 샘플 단위로 맞춰 동시에 틀고, 음량만 바꿔 끊김 없이 전환한다 (앱의 반주·보컬·원곡 스위치).
// 페이지에서 소리는 한 곳만: 누가 소리를 내기 시작하면(claimAudio) 다른 곳은 멈춘다.

export type StemMode = "inst" | "vocal" | "mix";
export type StemUrls = Record<StemMode, string>;

let shared: AudioContext | null = null;

/** 페이지 전체가 함께 쓰는 AudioContext (사용자 동작 안에서 처음 만든다) */
export function audioContext(): AudioContext {
  shared ??= new AudioContext();
  return shared;
}

// MARK: - 오디오 버스 (한 번에 한 곳만)

const owners = new Set<(owner: string) => void>();

/** owner 가 소리를 내기 시작한다 — 다른 곳은 멈추라고 알린다 */
export function claimAudio(owner: string) {
  owners.forEach((listener) => listener(owner));
}

/** 다른 곳이 소리를 내기 시작하면 불린다. 해제 함수를 돌려준다 */
export function onAudioClaim(listener: (owner: string) => void): () => void {
  owners.add(listener);
  return () => owners.delete(listener);
}

// MARK: - 버퍼 (주소별로 한 번만 받는다 — 첫 화면과 플레이어가 같은 곡을 나눠 쓴다)

const buffers = new Map<string, Promise<AudioBuffer>>();

function loadBuffer(ctx: AudioContext, url: string): Promise<AudioBuffer> {
  let pending = buffers.get(url);
  if (!pending) {
    pending = fetch(url)
      .then((response) => {
        if (!response.ok) throw new Error(`${url}: ${response.status}`);
        return response.arrayBuffer();
      })
      .then((data) => ctx.decodeAudioData(data));
    // 실패하면 다음에 다시 받게
    pending.catch(() => buffers.delete(url));
    buffers.set(url, pending);
  }
  return pending;
}

// MARK: - 스템 플레이어

export class StemPlayer {
  private readonly ctx: AudioContext;
  private readonly urls: Partial<StemUrls>;
  private stems: Partial<Record<StemMode, AudioBuffer>> = {};
  private sources: AudioBufferSourceNode[] = [];
  private readonly gains: Record<StemMode, GainNode>;
  private readonly master: GainNode;
  private startedAt = 0;
  private offset = 0;
  private mode: StemMode;
  playing = false;

  /** 필요한 트랙만 준다 (첫 화면은 원곡·반주만) */
  constructor(ctx: AudioContext, urls: Partial<StemUrls>, mode: StemMode = "mix") {
    this.ctx = ctx;
    this.urls = urls;
    this.mode = mode;
    this.master = ctx.createGain();
    this.master.connect(ctx.destination);
    this.gains = {
      inst: ctx.createGain(),
      vocal: ctx.createGain(),
      mix: ctx.createGain(),
    };
    for (const key of Object.keys(this.gains) as StemMode[]) {
      this.gains[key].gain.value = key === mode ? 1 : 0;
      this.gains[key].connect(this.master);
    }
  }

  async load(): Promise<void> {
    const entries = await Promise.all(
      (Object.keys(this.urls) as StemMode[]).map(async (key) => [key, await loadBuffer(this.ctx, this.urls[key] as string)] as const),
    );
    this.stems = Object.fromEntries(entries);
  }

  get duration(): number {
    return (this.stems.mix ?? this.stems.inst ?? this.stems.vocal)?.duration ?? 0;
  }

  get loaded(): boolean {
    return this.duration > 0;
  }

  /** 지금 위치 (초, 반복 안에서) */
  get position(): number {
    if (!this.duration) return 0;
    const raw = this.playing ? this.offset + (this.ctx.currentTime - this.startedAt) : this.offset;
    return ((raw % this.duration) + this.duration) % this.duration;
  }

  get currentMode(): StemMode {
    return this.mode;
  }

  play(from = this.offset, fadeIn = 0.25) {
    if (!this.loaded) return;
    this.stopSources();
    const at = this.ctx.currentTime + 0.03;
    // 세 트랙을 같은 시각·같은 위치에서 시작, 모두 반복 → 끝까지 어긋나지 않는다
    for (const key of Object.keys(this.gains) as StemMode[]) {
      const buffer = this.stems[key];
      if (!buffer) continue;
      const source = this.ctx.createBufferSource();
      source.buffer = buffer;
      source.loop = true;
      source.connect(this.gains[key]);
      source.start(at, from % buffer.duration);
      this.sources.push(source);
    }
    this.offset = from;
    this.startedAt = at;
    this.playing = true;
    this.master.gain.cancelScheduledValues(at);
    this.master.gain.setValueAtTime(0.0001, at);
    this.master.gain.exponentialRampToValueAtTime(1, at + fadeIn);
  }

  pause(fadeOut = 0.15) {
    if (!this.playing) return;
    this.offset = this.position;
    this.playing = false;
    const now = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(now);
    this.master.gain.setValueAtTime(this.master.gain.value, now);
    this.master.gain.linearRampToValueAtTime(0, now + fadeOut);
    const sources = this.sources;
    this.sources = [];
    window.setTimeout(() => sources.forEach((source) => safeStop(source)), fadeOut * 1000 + 30);
  }

  seek(seconds: number) {
    this.offset = Math.max(0, seconds);
    if (this.playing) this.play(this.offset, 0.06);
  }

  /** 반주·보컬·원곡 전환 (재생 중이면 fade 초 동안 음량만 바꾼다) */
  setMode(mode: StemMode, fade = 0.12) {
    this.mode = mode;
    const now = this.ctx.currentTime;
    for (const key of Object.keys(this.gains) as StemMode[]) {
      const gain = this.gains[key].gain;
      gain.cancelScheduledValues(now);
      gain.setValueAtTime(gain.value, now);
      gain.linearRampToValueAtTime(key === mode ? 1 : 0, now + fade);
    }
  }

  dispose() {
    this.stopSources();
    this.master.disconnect();
  }

  private stopSources() {
    this.sources.forEach((source) => safeStop(source));
    this.sources = [];
  }
}

function safeStop(source: AudioBufferSourceNode) {
  try {
    source.stop();
  } catch {
    // 이미 멈춘 소리
  }
}
