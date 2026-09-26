// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 배포판 정보. 새 버전을 올리면 여기만 바꾼다 (scripts/release.sh 가 출력하는 값).

export const release = {
  version: "0.2.0",
  /** GitHub Releases 에 올린 공증된 DMG */
  downloadUrl: "https://github.com/hsu3046/CoNoAI/releases/download/v0.2.0/CoNo-0.2.0.dmg",
  sizeLabel: "74 MB",
  sha256: "66ef1a4eddd445c3e80f02a01ea8c5a6dfa9a3ca977e71c0c4419be2f99bec9f",
  minimumMacOS: "macOS 15 Sequoia 이상",
  repositoryUrl: "https://github.com/hsu3046/CoNoAI",
  releasesUrl: "https://github.com/hsu3046/CoNoAI/releases",
} as const;

/** 나중에 찍을 영상. src 가 생기면 자리 표시 대신 영상이 나온다 */
export type VideoItem = {
  id: string;
  title: string;
  caption: string;
  /** mp4 경로 또는 YouTube 임베드 주소 */
  src?: string;
  poster?: string;
};

export const videos: VideoItem[] = [
  { id: "demo", title: "30초 만에 보는 CoNo", caption: "음악 앱에서 ▶ 누르면 벌어지는 일" },
  { id: "party", title: "진짜로 불러 봤습니다", caption: "거실 노래방 실전 — 점수는 과연?" },
];
