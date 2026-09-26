// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 점수 연출 미리보기 (영상 촬영·디자인 확인용): /demo/score?score=92 — 검색에 노출하지 않는다.

import type { Metadata } from "next";
import { ScoreDemo } from "./ScoreDemo";

export const metadata: Metadata = { title: "CoNo — 점수 연출 미리보기", robots: { index: false, follow: false } };

export default async function Page({ searchParams }: PageProps<"/demo/score">) {
  const params = await searchParams;
  const raw = Number(Array.isArray(params.score) ? params.score[0] : params.score);
  const score = Number.isFinite(raw) ? Math.min(100, Math.max(0, Math.round(raw))) : 92;
  return <ScoreDemo score={score} />;
}
