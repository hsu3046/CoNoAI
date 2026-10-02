// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
/* eslint-disable @next/next/no-html-link-for-pages -- Full navigation intentionally runs the editor/publisher beforeunload guard before discarding unsaved work. */
import type { Metadata } from "next";
import { LyricsLibrary } from "@/components/LyricsLibrary";
export const metadata: Metadata = { title: "내 가사 보관함 · CoNo", description: "직접 적은 가사와 TXT·LRC를 개인 보관함에 담고, 선택한 가사만 LRCLIB에 공개하세요.", robots: { index: false } };
export default function LyricsPage() {
  return <main className="mx-auto min-h-dvh max-w-6xl px-5 py-8 sm:px-8 sm:py-12">
    <nav aria-label="보관함 탐색" className="mb-12 flex flex-wrap items-center justify-between gap-5"><a href="/" className="font-cute text-3xl text-pink">CoNo</a><div className="flex gap-5 text-sm text-ink2"><a className="hover:text-ink" href="/#records">나의 기록</a><a className="hover:text-ink" href="/#download">Mac 앱 받기</a></div></nav>
    <p className="text-xs font-bold tracking-[0.25em] text-mint">MY LYRICS</p>
    <h1 className="mt-3 font-cute text-4xl sm:text-5xl">노래할 가사, 내 손으로.</h1>
    <p className="mt-5 max-w-2xl text-base leading-relaxed text-ink2">찾지 못한 가사도 직접 적거나 파일로 가져올 수 있어요. 나의 보관함에 담아 두고, 함께 나누고 싶은 가사만 LRCLIB에 공개하세요.</p>
    <LyricsLibrary />
    <footer className="mt-12 border-t border-white/10 pt-6 text-xs text-ink2">© 2026 <a className="underline" href="https://www.aib.vote">AIB Inc.</a> · 가사 파일은 TXT/LRC로 Mac 앱과 교환할 수 있습니다.</footer>
  </main>;
}
