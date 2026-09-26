// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 브라우저 체험곡 "우리 집 무대" — CoNo 가 직접 만든 8마디 멜로디와 가사 (저작권 걱정 없음).
// 96 BPM, 4/4, C장조. 음 하나 = 가사 한 글자.

export type MelodyNote = {
  /** MIDI 음 (60 = C4) */
  midi: number;
  /** 시작 박 (0부터) */
  beat: number;
  /** 길이 (박) */
  beats: number;
  syllable: string;
};

export const TEMPO = 96;
export const BEAT_SECONDS = 60 / TEMPO;
/** 시작 전 카운트 (박) */
export const COUNT_IN_BEATS = 4;

// [MIDI, 박 수, 글자] — 마디마다 4박
const bars: [number, number, string][][] = [
  [[60, 1, "오"], [64, 1, "늘 "], [67, 1, "밤"], [64, 1, "은 "]],
  [[65, 1.5, "우"], [64, 0.5, "리 "], [62, 2, "집"]],
  [[62, 1, "무"], [65, 1, "대 "], [69, 1, "위"], [65, 1, "로 "]],
  [[67, 1.5, "올"], [65, 0.5, "라"], [64, 2, "가"]],
  [[64, 1, "마"], [67, 1, "이"], [72, 1.5, "크"], [71, 0.5, "를 "]],
  [[69, 1, "꼭 "], [67, 1, "잡"], [65, 2, "고"]],
  [[64, 1, "소"], [62, 1, "리 "], [64, 1, "높"], [65, 1, "여 "]],
  [[60, 4, "팡!"]],
];

/** 글자 끝 공백은 낱말 끝 (가사를 그릴 때 띄운다) */
export const melody: MelodyNote[] = bars.flatMap((bar, index) => {
  let beat = index * 4;
  return bar.map(([midi, beats, syllable]) => {
    const note = { midi, beat, beats, syllable };
    beat += beats;
    return note;
  });
});

/** 마디별 화음 (근음 MIDI + 구성음) */
export const chords: { root: number; tones: number[] }[] = [
  { root: 48, tones: [60, 64, 67] }, // C
  { root: 53, tones: [60, 65, 69] }, // F
  { root: 50, tones: [62, 65, 69] }, // Dm
  { root: 55, tones: [59, 62, 67] }, // G
  { root: 48, tones: [60, 64, 67] }, // C
  { root: 53, tones: [60, 65, 69] }, // F
  { root: 55, tones: [59, 62, 67] }, // G
  { root: 48, tones: [60, 64, 67] }, // C
];

export const TOTAL_BEATS = bars.length * 4;
export const SONG_SECONDS = TOTAL_BEATS * BEAT_SECONDS;

/** 가사 줄 (두 마디씩) — 노래 중 화면 표시용 */
export const lyricLines: { from: number; to: number; text: string }[] = [0, 1, 2, 3].map((line) => {
  const notes = melody.filter((note) => note.beat >= line * 8 && note.beat < line * 8 + 8);
  return { from: line * 8, to: line * 8 + 8, text: notes.map((note) => note.syllable).join("").trim() };
});

export const midiToHz = (midi: number) => 440 * Math.pow(2, (midi - 69) / 12);
export const hzToMidi = (hz: number) => 69 + 12 * Math.log2(hz / 440);
