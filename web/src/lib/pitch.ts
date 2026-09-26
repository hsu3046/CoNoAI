// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 브라우저 마이크 음정 검출 (YIN, de Cheveigné & Kawahara 2002) + 채점 계산.
// 앱(SwiftF0 + SingingJudge)과 같은 규칙: 옥타브 무관, ±50센트, 음표별 60% 면 만점.

export type PitchReading = { hz: number; clarity: number; rms: number };

/**
 * YIN 음정 검출. buffer 길이는 window + 최대 주기보다 길어야 한다.
 * @returns 음정을 못 찾으면 null (무성·잡음)
 */
export function detectPitch(
  buffer: Float32Array,
  sampleRate: number,
  minHz = 70,
  maxHz = 1100,
  threshold = 0.15,
): PitchReading | null {
  let sum = 0;
  for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i];
  const rms = Math.sqrt(sum / buffer.length);
  const tauMin = Math.max(2, Math.floor(sampleRate / maxHz));
  const tauMax = Math.min(Math.floor(sampleRate / minHz), Math.floor(buffer.length / 2));
  const window = buffer.length - tauMax;
  if (window <= tauMin || rms < 1e-4) return null;

  // 차이 함수 → 누적 평균 정규화
  const d = new Float32Array(tauMax + 1);
  for (let tau = 1; tau <= tauMax; tau++) {
    let acc = 0;
    for (let i = 0; i < window; i++) {
      const delta = buffer[i] - buffer[i + tau];
      acc += delta * delta;
    }
    d[tau] = acc;
  }
  let running = 0;
  const cmnd = new Float32Array(tauMax + 1);
  cmnd[0] = 1;
  for (let tau = 1; tau <= tauMax; tau++) {
    running += d[tau];
    cmnd[tau] = running > 0 ? (d[tau] * tau) / running : 1;
  }

  // 문턱 아래 첫 골짜기
  let tau = -1;
  for (let t = tauMin; t <= tauMax; t++) {
    if (cmnd[t] < threshold) {
      while (t + 1 <= tauMax && cmnd[t + 1] < cmnd[t]) t++;
      tau = t;
      break;
    }
  }
  if (tau < 0) return null;

  // 포물선 보간으로 주기 세밀하게
  const x0 = tau > 1 ? cmnd[tau - 1] : cmnd[tau];
  const x2 = tau < tauMax ? cmnd[tau + 1] : cmnd[tau];
  const denominator = 2 * (2 * cmnd[tau] - x2 - x0);
  const shift = denominator !== 0 ? (x2 - x0) / denominator : 0;
  const period = tau + shift;
  return { hz: sampleRate / period, clarity: 1 - cmnd[tau], rms };
}

/** 부른 음 − 기준 음 (반음), 옥타브를 접어 [-6, 6) */
export function foldedOffset(sung: number, reference: number): number {
  let offset = (sung - reference) % 12;
  if (offset >= 6) offset -= 12;
  else if (offset < -6) offset += 12;
  return offset;
}

export type NoteTally = { frames: number; hits: number; seconds: number };

export type SongScore = { score: number; notesHit: number; notesTotal: number; bestStreak: number };

/** 음표별 집계 → 점수 (앱의 NoteScorer 와 같은 규칙) */
export function scoreSong(tallies: NoteTally[], fullCreditRatio = 0.6, hitRatio = 0.5): SongScore {
  let credit = 0;
  let total = 0;
  let notesHit = 0;
  let streak = 0;
  let bestStreak = 0;
  for (const tally of tallies) {
    const ratio = tally.frames > 0 ? tally.hits / tally.frames : 0;
    total += tally.seconds;
    credit += tally.seconds * Math.min(1, ratio / fullCreditRatio);
    if (ratio >= hitRatio) {
      notesHit += 1;
      streak += 1;
      bestStreak = Math.max(bestStreak, streak);
    } else {
      streak = 0;
    }
  }
  return {
    score: total > 0 ? Math.round((credit / total) * 100) : 0,
    notesHit,
    notesTotal: tallies.length,
    bestStreak,
  };
}

export function scoreComment(score: number): string {
  if (score >= 95) return "완벽해요!";
  if (score >= 85) return "훌륭해요!";
  if (score >= 70) return "좋아요!";
  if (score >= 50) return "조금만 더!";
  return "연습하면 늘어요";
}
