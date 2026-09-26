// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

"use client";

import { useState } from "react";
import { ScoreShow } from "@/components/ScoreShow";

export function ScoreDemo({ score }: { score: number }) {
  const [run, setRun] = useState(0);
  const [audio, setAudio] = useState<AudioContext | null>(null);
  const [open, setOpen] = useState(false);
  const total = 26;
  const hit = Math.round((total * score) / 100);
  return (
    <main className="grid min-h-dvh place-items-center">
      <button
        type="button"
        onClick={() => {
          // 소리는 사용자 동작 뒤에만 켤 수 있다
          const context = audio ?? new AudioContext();
          setAudio(context);
          void context.resume();
          setRun((value) => value + 1);
          setOpen(true);
        }}
        className="rounded-full bg-pink px-8 py-4 font-cute text-2xl text-night"
      >
        {score}점 연출 보기
      </button>
      {open && (
        <ScoreShow
          key={run}
          result={{ score, notesHit: hit, notesTotal: total, bestStreak: Math.max(1, hit - 3) }}
          audio={audio}
          onClose={() => setOpen(false)}
          onRetry={() => setRun((value) => value + 1)}
        />
      )}
    </main>
  );
}
