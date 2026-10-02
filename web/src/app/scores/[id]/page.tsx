import Link from "next/link";
// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { repository } from "@/lib/local-repository";
import { UUID } from "@/lib/score-record";
import { ScoreActions } from "@/components/ScoreActions";
export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "CoNo · 함께 부르는 무대", robots: { index: false, follow: false } };
export default async function SharedScore({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  let data;
  try { data = await repository().read(); }
  catch { return <main className="grid min-h-dvh place-items-center p-8"><div><h1 className="text-2xl">기록을 불러오지 못했어요.</h1><p>로컬 서버가 실행 중인지 확인한 뒤 새로고침해 주세요.</p><Link href="/#records" className="text-mint underline">나의 기록</Link></div></main>; }
  const entry = data.scores.find((v) => v.record.id === id.toLowerCase() && v.published);
  if (!entry) notFound();
  const r = entry.record;
  const name = data.profiles[entry.ownerId]?.nickname ?? "나의 무대";
  return <main className="grid min-h-dvh place-items-center p-6"><article className="w-full max-w-2xl rounded-[36px] border border-gold/30 bg-gradient-to-br from-night to-[#29123e] p-8 text-center sm:p-12">
    <Link href="/" className="font-display text-2xl text-mint">CoNo</Link><p className="mt-5 text-ink2">{name}의 무대</p><h1 className="mt-4 font-cute text-3xl">{r.title}</h1><p className="text-ink2">{r.artist}</p><p className="my-5 font-display text-8xl text-gold">{r.score}<small className="text-2xl">점</small></p>
    <p className="mb-5 text-ink2">음표 {r.notesHit}/{r.notesTotal} · 최고 연속 {r.bestStreak} · {r.source === "macos" ? "Mac" : "브라우저"} · {r.difficulty === "hard" ? "어려움" : "보통"}</p>
    <ScoreActions record={r} published /><Link href="/#try" className="mt-6 inline-block rounded-full bg-pink px-8 py-3 font-cute text-xl text-night">나도 도전하기 →</Link><p className="mt-6 text-xs text-faint">로컬 테스트 · 사용자 제공 점수 · AIB Inc.</p>
  </article></main>;
}
