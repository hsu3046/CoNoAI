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
  { id: "demo", title: "듣던 노래가 반주로", caption: "원곡과 AI 반주를 직접 비교해 보세요" },
  { id: "party", title: "내 목소리로 채점 체험", caption: "한 곡을 마치고 기록·공유까지" },
];
