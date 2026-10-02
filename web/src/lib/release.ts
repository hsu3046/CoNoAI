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

/** 로컬 웹에서 직접 캡처한 기능 안내. 소리·음성 녹음은 포함하지 않는다. */
export type VideoItem = {
  id: string;
  title: string;
  caption: string;
  src: string;
  poster: string;
  captions: string;
  transcript: string[];
  action: { href: string; label: string };
};

export const videos: VideoItem[] = [
  {
    id: "demo", title: "원곡에서 반주, 보컬까지", caption: "실제 웹 화면으로 보는 소리 전환 · 무음 안내",
    src: "/videos/listen-guide.mp4", poster: "/videos/listen-guide.jpg", captions: "/videos/listen-guide.ko.vtt",
    transcript: ["곡을 고르고 재생합니다.", "‘반주’를 누르면 가수 목소리를 제거한 소리로 바뀝니다.", "‘보컬’을 누르면 가수 목소리만 들을 수 있습니다. 실제 소리는 ‘들어보기’에서 비교하세요."],
    action: { href: "#listen", label: "직접 소리 비교하기" },
  },
  {
    id: "scores", title: "한 곡의 기록을 공유하기", caption: "테스트 기록으로 보는 JSON 백업·공유·챌린지 · 무음 안내",
    src: "/videos/scores-guide.mp4", poster: "/videos/scores-guide.jpg", captions: "/videos/scores-guide.ko.vtt",
    transcript: ["나의 기록에서 점수 확인, JSON 백업, 이미지 저장을 할 수 있습니다.", "챌린지에 공개한 기록은 공유 페이지로 연결됩니다. localhost 링크는 같은 컴퓨터에서만 열립니다.", "같은 곡·난이도·채점 방식의 개인 최고 기록으로 순위를 매깁니다. 영상의 92점은 테스트 기록입니다."],
    action: { href: "#records", label: "나의 기록 열기" },
  },
];
