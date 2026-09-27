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

/** 켜질 때 (초) */
export const FADE_IN = 1.2;
/** 꺼질 때 (초) */
export const FADE_OUT = 1.0;
/** 반주·보컬·원곡 전환 (초) */
export const MODE_FADE = 0.35;
/** 위치 이동 때 앞뒤 소리를 겹치는 길이 (초) */
const SEEK_FADE = 0.12;

/** 켜고 끄는 페이드의 바닥 (이보다 작으면 들리지 않는 것으로 친다) */
const FLOOR_DB = -40;

/**
 * 부드러운 음량 곡선. 진행 중인 곡선의 현재 값에서 이어 간다 (cancelAndHoldAtTime 이 없는 Firefox 도 같게: 값 읽기 → 고정 → 곡선).
 * - "level" (켜기·끄기): dB 로 부드럽게 (smoothstep). 귀는 dB 로 듣기 때문에 음량 비율로 곡선을 그리면
 *   끌 때 앞 절반은 그대로 크다가 끝에서 뚝 떨어지고, 켤 때는 첫 순간 툭 튀어나온다.
 * - "cross" (반주·원곡 전환): 두 소리가 맞물리므로 음량 비율의 반 코사인.
 */
function glide(param: AudioParam, to: number, at: number, duration: number, shape: "level" | "cross" = "cross") {
  const from = param.value;
  param.cancelScheduledValues(at);
  param.setValueAtTime(from, at);
  if (duration < 0.02 || Math.abs(to - from) < 1e-4) {
    param.setValueAtTime(to, at + 0.001);
    return;
  }
  const curve = new Float32Array(128);
  const floor = 10 ** (FLOOR_DB / 20);
  const toDb = (x: number) => (x <= floor ? FLOOR_DB : 20 * Math.log10(x));
  for (let i = 0; i < curve.length; i++) {
    const k = i / (curve.length - 1);
    if (shape === "cross") {
      curve[i] = from + (to - from) * (0.5 - 0.5 * Math.cos(Math.PI * k));
    } else {
      const eased = k * k * (3 - 2 * k);
      const db = toDb(from) + (toDb(to) - toDb(from)) * eased;
      // 바닥을 빼고 늘려 양 끝이 정확히 0 이 되게
      curve[i] = Math.max(0, (10 ** (db / 20) - floor) / (1 - floor));
    }
  }
  // 고정한 값과 겹치지 않게 아주 조금 뒤에서 시작
  param.setValueCurveAtTime(curve, at + 0.005, duration);
}

/** 한 번 재생할 때마다 만드는 소리 경로: 스템별 음량 → 페이더. 멈추는 소리는 자기 페이더로 사라지고 새 소리와 겹친다 */
type Take = { sources: AudioBufferSourceNode[]; stems: Record<StemMode, GainNode>; fader: GainNode };

export class StemPlayer {
  private readonly ctx: AudioContext;
  private readonly urls: Partial<StemUrls>;
  private stems: Partial<Record<StemMode, AudioBuffer>> = {};
  private take: Take | null = null;
  private startedAt = 0;
  private offset = 0;
  private mode: StemMode;
  playing = false;
  /** 한 번이라도 틀었는지 (첫 재생 위치를 따로 정할 때) */
  playedOnce = false;

  /** 필요한 트랙만 준다 (첫 화면은 원곡·반주만) */
  constructor(ctx: AudioContext, urls: Partial<StemUrls>, mode: StemMode = "mix") {
    this.ctx = ctx;
    this.urls = urls;
    this.mode = mode;
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

  play(from = this.offset, fadeIn = FADE_IN) {
    if (!this.loaded) return;
    // 이미 나던 소리는 새 소리가 들어오는 동안 사라진다 (겹쳐서 이어짐)
    this.release(Math.min(fadeIn, FADE_OUT));
    const at = this.ctx.currentTime + 0.03;
    const fader = this.ctx.createGain();
    fader.gain.value = 0;
    fader.connect(this.ctx.destination);
    const stems = {} as Record<StemMode, GainNode>;
    const sources: AudioBufferSourceNode[] = [];
    for (const key of ["inst", "vocal", "mix"] as StemMode[]) {
      const gain = this.ctx.createGain();
      gain.gain.value = key === this.mode ? 1 : 0;
      gain.connect(fader);
      stems[key] = gain;
      const buffer = this.stems[key];
      if (!buffer) continue;
      // 세 트랙을 같은 시각·같은 위치에서 시작, 모두 반복 → 끝까지 어긋나지 않는다
      const source = this.ctx.createBufferSource();
      source.buffer = buffer;
      source.loop = true;
      source.connect(gain);
      source.start(at, from % buffer.duration);
      sources.push(source);
    }
    glide(fader.gain, 1, at, fadeIn, "level");
    this.take = { sources, stems, fader };
    this.offset = from;
    this.startedAt = at;
    this.playing = true;
  }

  pause(fadeOut = FADE_OUT) {
    if (!this.playing) return;
    this.offset = this.position;
    this.playing = false;
    this.release(fadeOut);
  }

  seek(seconds: number) {
    this.offset = Math.max(0, seconds);
    if (this.playing) this.play(this.offset, SEEK_FADE);
  }

  /** 반주·보컬·원곡 전환 (재생 중이면 fade 초 동안 음량만 바꾼다) */
  setMode(mode: StemMode, fade = MODE_FADE) {
    this.mode = mode;
    if (!this.take) return;
    const now = this.ctx.currentTime;
    for (const key of Object.keys(this.take.stems) as StemMode[]) {
      glide(this.take.stems[key].gain, key === mode ? 1 : 0, now, fade);
    }
  }

  /** 버리기 — 나던 소리도 서서히 사라진 뒤 정리 */
  dispose(fadeOut = FADE_OUT) {
    this.playing = false;
    this.release(fadeOut);
  }

  /** 지금 소리 경로를 fade 초 동안 줄이고 정리 */
  private release(fade: number) {
    const take = this.take;
    if (!take) return;
    this.take = null;
    glide(take.fader.gain, 0, this.ctx.currentTime, fade, "level");
    window.setTimeout(() => {
      take.sources.forEach((source) => safeStop(source));
      take.fader.disconnect();
    }, fade * 1000 + 80);
  }
}

function safeStop(source: AudioBufferSourceNode) {
  try {
    source.stop();
  } catch {
    // 이미 멈춘 소리
  }
}
