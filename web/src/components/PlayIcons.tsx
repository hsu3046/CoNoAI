// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 재생·일시정지 아이콘 (글자 ▶ ❚❚ 는 글꼴마다 굵기·비율이 달라 뭉툭해진다 → SVG 로 모양을 고정)

export function PlayPauseIcon({ playing, size = 24 }: { playing: boolean; size?: number }) {
  return playing ? (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <rect x="6" y="4.5" width="4" height="15" rx="1.3" />
      <rect x="14" y="4.5" width="4" height="15" rx="1.3" />
    </svg>
  ) : (
    // 삼각형은 무게중심이 왼쪽이라 살짝 오른쪽으로
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M8.5 5.2c0-1 1.1-1.6 1.9-1.1l9.4 6.3c.8.5.8 1.7 0 2.2l-9.4 6.3c-.8.5-1.9-.1-1.9-1.1z" />
    </svg>
  );
}
