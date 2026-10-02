// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

"use client";

import { useState } from "react";
import { ScoreShow } from "@/components/ScoreShow";
import { audioContext, claimAudio } from "@/fx/stems";

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
        onClick={async () => {
          // 소리는 사용자 동작 뒤에만 켤 수 있다
          claimAudio("score-demo");
          let context: AudioContext | null = null;
          try { context = audioContext(); await context.resume(); }
          catch { context = null; } // 소리가 지원되지 않아도 점수와 공유 UI는 표시한다.
          setAudio(context);
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
